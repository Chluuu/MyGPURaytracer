#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/partition.h>
#include <thrust/copy.h>
#include <thrust/device_vector.h>

#include <stream_compaction/cpu.h>
#include <stream_compaction/naive.h>
#include <stream_compaction/efficient.h>
#include <stream_compaction/thrust.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#include "timer.h"
PerformanceTimer& timer()
{
    static PerformanceTimer timer;
    return timer;
}
#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)

#define DEPTH_OF_FIELD 0
#define CACHE_FIRST_BOUNCE 1
#define SORT_BY_MATERIAL 1
#define ANTIALIASING 1
#define BOUNDING_BOX 0

void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err) {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file) {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
    getchar();
#  endif
    exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
        int iter, glm::vec3* image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int) (pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int) (pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int) (pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
// TODO: static variables for device memory, any extra info you need, etc
static ShadeableIntersection* dev_first_intersections = NULL;


void pathtraceInit(Scene *scene) {
    hst_scene = scene;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

  	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

    for (int i = 0; i < scene->geoms.size(); i++)
    {
        Geom& geom = scene->geoms[i];
        cudaMalloc(&geom.dev_faces, geom.faceSize * sizeof(Face));
        cudaMemcpy(geom.dev_faces, (scene->allFaces[i]).data(), geom.faceSize * sizeof(Face), cudaMemcpyHostToDevice);

        geom.kd.channels = scene->kdTextures[i].channels;
        geom.kd.width = scene->kdTextures[i].width;
        geom.kd.height = scene->kdTextures[i].height;
        cudaMalloc(&geom.kd.image, scene->kdTextures[i].width * scene->kdTextures[i].height * scene->kdTextures[i].channels * sizeof(unsigned char));
        cudaMemcpy(geom.kd.image, scene->kdTextures[i].image, scene->kdTextures[i].width * scene->kdTextures[i].height * scene->kdTextures[i].channels * sizeof(unsigned char), cudaMemcpyHostToDevice);

        geom.ks.channels = scene->ksTextures[i].channels;
        geom.ks.width = scene->ksTextures[i].width;
        geom.ks.height = scene->ksTextures[i].height;
        cudaMalloc(&geom.ks.image, scene->ksTextures[i].width * scene->ksTextures[i].height * scene->ksTextures[i].channels * sizeof(unsigned char));
        cudaMemcpy(geom.ks.image, scene->ksTextures[i].image, scene->ksTextures[i].width * scene->ksTextures[i].height * scene->ksTextures[i].channels * sizeof(unsigned char), cudaMemcpyHostToDevice);

        geom.ke.channels = scene->keTextures[i].channels;
        geom.ke.width = scene->keTextures[i].width;
        geom.ke.height = scene->keTextures[i].height;
        cudaMalloc(&geom.ke.image, scene->keTextures[i].width * scene->keTextures[i].height * scene->keTextures[i].channels * sizeof(unsigned char));
        cudaMemcpy(geom.ke.image, scene->keTextures[i].image, scene->keTextures[i].width * scene->keTextures[i].height * scene->keTextures[i].channels * sizeof(unsigned char), cudaMemcpyHostToDevice);

        geom.bump.channels = scene->bumpTextures[i].channels;
        geom.bump.width = scene->bumpTextures[i].width;
        geom.bump.height = scene->bumpTextures[i].height;
        cudaMalloc(&geom.bump.image, scene->bumpTextures[i].width * scene->bumpTextures[i].height * scene->bumpTextures[i].channels * sizeof(unsigned char));
        cudaMemcpy(geom.bump.image, scene->bumpTextures[i].image, scene->bumpTextures[i].width * scene->bumpTextures[i].height * scene->bumpTextures[i].channels * sizeof(unsigned char), cudaMemcpyHostToDevice);
    }

    cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
    cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
  	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
  	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

    // TODO: initialize any extra device memeory you need
#if CACHE_FIRST_BOUNCE
        cudaMalloc(&dev_first_intersections, pixelcount* sizeof(ShadeableIntersection));
        cudaMemset(dev_first_intersections, 0, pixelcount* sizeof(ShadeableIntersection));
#endif
    checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
    if (hst_scene != NULL) {
        for (int i = 0; i < hst_scene->geoms.size(); i++)
        {
            Geom& geom = hst_scene->geoms[i];
            cudaFree(geom.dev_faces);
            cudaFree(geom.kd.image);
            cudaFree(geom.ks.image);
            cudaFree(geom.ke.image);
            cudaFree(geom.bump.image);
        }
    }
    cudaFree(dev_image);  // no-op if dev_image is null
  	cudaFree(dev_paths);
  	cudaFree(dev_geoms);
  	cudaFree(dev_materials);
  	cudaFree(dev_intersections);
    // TODO: clean up any extra device memory you created
#if CACHE_FIRST_BOUNCE
        cudaFree(dev_first_intersections);
#endif
    checkCUDAError("pathtraceFree");
}

__host__ __device__ glm::vec2 ConcentricSampleDisk(const glm::vec2 &point) {
    glm::vec2 uOffset = 2.f * point - glm::vec2(1, 1);
    if (uOffset.x == 0 && uOffset.y == 0)
        return glm::vec2(0, 0);
    float theta, r;
    if (std::abs(uOffset.x) > std::abs(uOffset.y)) {
        r = uOffset.x;
        theta = 0.785398f * (uOffset.y / uOffset.x);
    }
    else {
        r = uOffset.y;
        theta = 1.570796f - 0.785398f * (uOffset.x / uOffset.y);
    }
    return r * glm::vec2(std::cos(theta), std::sin(theta));
}
/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;


	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment & segment = pathSegments[index];

        thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, traceDepth);

		segment.ray.origin = cam.position;
        segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

        float antia_x = x;
        float antia_y = y;
#if ANTIALIASING
        thrust::default_random_engine rngANTIA = makeSeededRandomEngine(iter, index, traceDepth);
        thrust::uniform_real_distribution<float> uANTIA(-0.5, 0.5);

        antia_x += uANTIA(rngANTIA);
        antia_y += uANTIA(rngANTIA);

#endif
		// TODO: implement antialiasing by jittering the ray
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)antia_x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)antia_y - (float)cam.resolution.y * 0.5f)
			);
#if DEPTH_OF_FIELD
        float lensRadius = 0.8f;
        float focalDistance = 11.0f;

        thrust::uniform_real_distribution<float> uDOF(0,1);

        if (lensRadius > 0) {
            glm::vec2 pLens = lensRadius * ConcentricSampleDisk(glm::vec2(uDOF(rng), uDOF(rng)));

            float ft = glm::abs(focalDistance / segment.ray.direction.z);
            glm::vec3 pFocus = segment.ray.origin+segment.ray.direction*ft;

            segment.ray.origin += glm::vec3(pLens.x, pLens.y, 0);
            segment.ray.direction = normalize(pFocus- segment.ray.origin);
        }
#endif
		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment * pathSegments
	, Geom * geoms
	, int geoms_size
	, ShadeableIntersection * intersections
	)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;
        glm::vec2 uv = glm::vec2(0.0f,0.0f);

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;
        glm::vec2 tmp_uv;

		// naive parse through global geoms
        //TODO BVH
		for (int i = 0; i < geoms_size; i++)
		{
			Geom & geom = geoms[i];
            int a = geom.faceSize;
            int b = geom.type;
			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			// TODO: add more intersection tests here... triangle? metaball? CSG?
            else if (geom.type == OBJ)
            {
#if BOUNDING_BOX
                if (boudingBoxIntersectionTest(geom, pathSegment.ray)) {
                    t = meshIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
                }
                else t = -1;
#endif
                //Although self-writing triangle intersect can also be used to cal t, it's slower than glm::intersectRayTriangle
                //t = objTriIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
                t = meshIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, tmp_uv, outside);
            }
			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
                uv = tmp_uv;
                int x = uv.x;
                int y = uv.y;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
            intersections[path_index].geomId = hit_geom_index;
            intersections[path_index].texcoord = uv;
		}
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial (
  int iter
  , int num_paths
	, ShadeableIntersection * shadeableIntersections
	, PathSegment * pathSegments
	, Material * materials
    , Geom* geoms
    , int depth
	)
{
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < num_paths)
  {
    ShadeableIntersection intersection = shadeableIntersections[idx];
    if (intersection.t > 0.0f) { // if the intersection exists...
      // Set up the RNG
      // LOOK: this is how you use thrust's RNG! Please look at
      // makeSeededRandomEngine as well.
      thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
      thrust::uniform_real_distribution<float> u01(0, 1);

      Material material = materials[intersection.materialId];
      glm::vec3 materialColor = material.color;

      // If the material indicates that the object was a light, "light" the ray
      if (material.emittance > 0.0f) {
        pathSegments[idx].color *= (materialColor * material.emittance);
        pathSegments[idx].remainingBounces = 0;
      }
      // Otherwise, do some pseudo-lighting computation. This is actually more
      // like what you would expect from shading in a rasterizer like OpenGL.
      // TODO: replace this! you should be able to start with basically a one-liner
      else if (pathSegments[idx].remainingBounces == 1) {
          pathSegments[idx].color = glm::vec3(0.0);
          pathSegments[idx].remainingBounces = 0;
      }
      else {
          scatterRay(pathSegments[idx], pathSegments[idx].ray.origin+intersection.t* pathSegments[idx].ray.direction, intersection, material, rng, geoms, iter, depth);
          pathSegments[idx].remainingBounces -= 1;
      }
    // If there was no intersection, color the ray black.
    // Lots of renderers use 4 channel color, RGBA, where A = alpha, often
    // used for opacity, in which case they can indicate "no opacity".
    // This can be useful for post-processing and image compositing.
    } else {
      pathSegments[idx].color = glm::vec3(0.0f);
      pathSegments[idx].remainingBounces = 0;
    }
  }
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

struct sortByMaterial {
    __host__ __device__ bool operator() (const ShadeableIntersection& a, const ShadeableIntersection& b){
        return a.materialId > b.materialId;
    }
};

struct isTerminate {
    __host__ __device__ bool operator()(const PathSegment& p) {
        return p.remainingBounces > 0;
    }
};
/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter) {
    const int traceDepth = hst_scene->state.traceDepth;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

    ///////////////////////////////////////////////////////////////////////////

    // Recap:
    // * Initialize array of path rays (using rays that come out of the camera)
    //   * You can pass the Camera object to that kernel.
    //   * Each path ray must carry at minimum a (ray, color) pair,
    //   * where color starts as the multiplicative identity, white = (1, 1, 1).
    //   * This has already been done for you.
    // * For each depth:
    //   * Compute an intersection in the scene for each path ray.
    //     A very naive version of this has been implemented for you, but feel
    //     free to add more primitives and/or a better algorithm.
    //     Currently, intersection distance is recorded as a parametric distance,
    //     t, or a "distance along the ray." t = -1.0 indicates no intersection.
    //     * Color is attenuated (multiplied) by reflections off of any object
    //   * TODO: Stream compact away all of the terminated paths.
    //     You may use either your implementation or `thrust::remove_if` or its
    //     cousins.
    //     * Note that you can't really use a 2D kernel launch any more - switch
    //       to 1D.
    //   * TODO: Shade the rays that intersected something or didn't bottom out.
    //     That is, color the ray by performing a color computation according
    //     to the shader, then generate a new ray to continue the ray path.
    //     We recommend just updating the ray's PathSegment in place.
    //     Note that this step may come before or after stream compaction,
    //     since some shaders you write may also cause a path to terminate.
    // * Finally, add this iteration's results to the image. This has been done
    //   for you.

    // TODO: perform one iteration of path tracing

	generateRayFromCamera <<<blocksPerGrid2d, blockSize2d >>>(cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;
    int num_paths_origin = num_paths;
	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks
    dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
    bool iterationComplete = false;
    timer().startGpuTimer();
	while (!iterationComplete) {
        dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
#if CACHE_FIRST_BOUNCE && !ANTIALIASING && !DEPTH_OF_FIELD
        if (depth==0 && iter!=1) {
            thrust::copy(thrust::device, dev_first_intersections, dev_first_intersections+ num_paths_origin, dev_intersections);
#if SORT_BY_MATERIAL
                thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + num_paths_origin, dev_paths, sortByMaterial());
#endif
        }
#endif
            // clean shading chunks
            cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

            // tracing
            computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
                depth
                , num_paths
                , dev_paths
                , dev_geoms
                , hst_scene->geoms.size()
                , dev_intersections
                );
            checkCUDAError("trace one bounce");
            cudaDeviceSynchronize();
#if CACHE_FIRST_BOUNCE && !ANTIALIASING && !DEPTH_OF_FIELD
            if (iter == 1 && depth == 0)thrust::copy(thrust::device, dev_intersections, dev_intersections + num_paths_origin, dev_first_intersections);
#endif
#if SORT_BY_MATERIAL
            thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + num_paths, dev_paths, sortByMaterial());
#endif
	depth++;


	// TODO:
	// --- Shading Stage ---
	// Shade path segments based on intersections and generate new rays by
  // evaluating the BSDF.
  // Start off with just a big kernel that handles all the different
  // materials you have in the scenefile.
  // TODO: compare between directly shading the path segments and shading
  // path segments that have been reshuffled to be contiguous in memory.
  shadeFakeMaterial<<<numblocksPathSegmentTracing, blockSize1d>>> (
    iter,
    num_paths,
    dev_intersections,
    dev_paths,
    dev_materials,
    dev_geoms,
    depth
  );
  //thrust::remove_if(dev_paths, dev_paths+num_paths, isTerminate());
  dev_path_end = thrust::stable_partition(thrust::device, dev_paths, dev_paths + num_paths, isTerminate());
  num_paths= dev_path_end - dev_paths;
  if(num_paths==0)iterationComplete = true; // TODO: should be based off stream compaction results.
	}
    timer().endGpuTimer();
  // Assemble this iteration and apply it to the image
	finalGather<<<numBlocksPixels, blockSize1d>>>(num_paths_origin, dev_image, dev_paths);

    ///////////////////////////////////////////////////////////////////////////

    // Send results to OpenGL buffer for rendering
    sendImageToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, iter, dev_image);

    // Retrieve image from GPU
    cudaMemcpy(hst_scene->state.image.data(), dev_image,
            pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
    checkCUDAError("pathtrace");
}
