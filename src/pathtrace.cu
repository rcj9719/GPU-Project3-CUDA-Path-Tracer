#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/partition.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#include <device_launch_parameters.h>

#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)

#define PIOVER4 0.78539816339
#define PIOVER2 1.57079632679
#define PI 3.14159265359

#define ANTIALIASING 0
#define CACHEINTERSECTIONS 1
#define DOF 0
#define SORTMATERIALS 1

#define DENOISER 1
#define DENOISER_EDGE_AVOIDING 1

void checkCUDAErrorFn(const char* msg, const char* file, int line) {
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
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

// CHECKITOUT4: process the gbuffer results and send them to OpenGL buffer for visualization
__global__ void gDepthBufferToPBO(uchar4* pbo, glm::ivec2 resolution, GBufferPixel* gBuffer) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		float timeToIntersect = gBuffer[index].t * 10.0;

		pbo[index].w = 0;
		pbo[index].x = timeToIntersect;
		pbo[index].y = timeToIntersect;
		pbo[index].z = timeToIntersect;
	}
}

__global__ void gNormalBufferToPBO(uchar4* pbo, glm::ivec2 resolution, GBufferPixel* gBuffer) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 perPixelNormal = abs(gBuffer[index].nor) * glm::vec3(255.f, 255.f, 255.f);
		pbo[index].w = 0;
		pbo[index].x = perPixelNormal.x;
		pbo[index].y = perPixelNormal.y;
		pbo[index].z = perPixelNormal.z;
	}
}

__global__ void gPositionBufferToPBO(uchar4* pbo, glm::ivec2 resolution, GBufferPixel* gBuffer) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 perPixelPosition = abs(gBuffer[index].pos) * glm::vec3(40.f, 40.f, 40.f);
		pbo[index].w = 0;
		pbo[index].x = glm::clamp(perPixelPosition.x, 0.f, 255.f);
		pbo[index].y = glm::clamp(perPixelPosition.y, 0.f, 255.f);
		pbo[index].z = glm::clamp(perPixelPosition.z, 0.f, 255.f);
	}
}

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static ShadeableIntersection* dev_intersections = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...
static ShadeableIntersection* dev_cache_intersections = NULL;
static GBufferPixel* dev_gBuffer = NULL;
static float* dev_filter = NULL;
static glm::ivec2* dev_filterOffsets = NULL;
static glm::vec3* dev_denoised_image_input = NULL;
static glm::vec3* dev_denoised_image_output = NULL;

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
}

//void generateFilter(float *filter) {
//	/*filter = {
//		0.0625, 0.0625, 0.0625, 0.0625, 0.0625,
//		0.0625, 0.25, 0.25, 0.25, 0.0625,
//		0.0625, 0.25, 0.375, 0.25, 0.0625,
//		0.0625, 0.25, 0.25, 0.25, 0.0625,
//		0.0625, 0.0625, 0.0625, 0.0625, 0.0625	
//	};*/
//	int filterSize = 5;
//	for (int i = -2; i <= 2; i++) {
//		for (int j = -2; j <= 2; j++) {
//			filter[] = 2;
//		}
//	}
//
//}

void generateFilterOffsets(std::vector<glm::ivec2> &filterOffsets, std::vector<float> &filter) {
	for (int i = -2; i <= 2; i++) {
		for (int j = -2; j <= 2; j++) {
			
			filterOffsets.push_back(glm::ivec2(i, j));
			
			float temp;
			temp = (pow(0.25, (abs(i) + abs(j))));

			if (i == 0 && j == 0) {
				temp = (0.375 * 0.375);
			}
			else if (i == 0 || j == 0) {
				temp *= 0.375;
			}
			filter.push_back(temp);
		}
	}

}

void pathtraceInit(Scene* scene) {
	hst_scene = scene;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	std::vector<float> filter;
	std::vector<glm::ivec2> filterOffsets;
	generateFilterOffsets(filterOffsets, filter);
	for (auto& f : filter) {
		printf("%f, ", f);
	}
	for (auto& f : filterOffsets) {
		printf("(%d, %d), ", f.x, f.y);
	}

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

	for (auto& geom : scene->geoms) {
		if (geom.type == OBJ)
		{
			cudaMalloc(&geom.dev_triangles, geom.triCount * sizeof(Triangle));
			cudaMemcpy(geom.dev_triangles, geom.triangles, geom.triCount * sizeof(Triangle), cudaMemcpyHostToDevice);
		}
	}
	
	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	// TODO: initialize any extra device memeory you need
#if CACHEINTERSECTIONS
	cudaMalloc(&dev_cache_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_cache_intersections, 0, pixelcount * sizeof(ShadeableIntersection));
#endif

	cudaMalloc(&dev_gBuffer, pixelcount * sizeof(GBufferPixel));
	cudaMemset(dev_gBuffer, 0, pixelcount * sizeof(GBufferPixel));

	cudaMalloc(&dev_filter, 25 * sizeof(float));
	cudaMemcpy(dev_filter, filter.data(), 25 * sizeof(float), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_filterOffsets, 25 * sizeof(glm::ivec2));
	cudaMemcpy(dev_filterOffsets, filterOffsets.data(), 25 * sizeof(glm::ivec2), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_denoised_image_input, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_denoised_image_input, 0, pixelcount * sizeof(glm::vec3));
	
	cudaMalloc(&dev_denoised_image_output, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_denoised_image_output, 0, pixelcount * sizeof(glm::vec3));
	checkCUDAError("pathtraceInit");
}

void pathtraceFree(Scene* scene) {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);

	//for (auto& geom : scene->geoms) {
	//	for (int i = 0; i < geom.triCount; i++) {
	//		//delete(geom.triangles);
	//		cudaFree(geom.dev_triangles);
	//	}
	//}

	cudaFree(dev_geoms);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	// TODO: clean up any extra device memory you created

	cudaFree(dev_gBuffer);
	cudaFree(dev_filter);
	cudaFree(dev_filterOffsets);
	cudaFree(dev_denoised_image_input);
	cudaFree(dev_denoised_image_output);

#if CACHEINTERSECTIONS
	cudaFree(dev_cache_intersections);
#endif

	checkCUDAError("pathtraceFree");

}

__host__ __device__ glm::vec2 concentricDiskSampling(const glm::vec2 &u) {

	//Map uniform random numbers to [-1, 1]
	glm::vec2 uOffset = 2.f * u - glm::vec2(1.f, 1.f);

	// Handle degeneracy at origin
	if (uOffset.x == 0 && uOffset.y == 0)
		return glm::vec2(0.f, 0.f);

	// Apply concentric mapping to point
	float theta, r;
	if (std::abs(uOffset.x) > std::abs(uOffset.y)) {
		r = uOffset.x;
		theta = PIOVER4 * (uOffset.y / uOffset.x);
	}
	else {
		r = uOffset.y;
		theta = PIOVER2 - PIOVER4 * (uOffset.x / uOffset.y);
	}
	return r * glm::vec2(cos(theta), sin(theta));
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
	thrust::default_random_engine rng = makeSeededRandomEngine(iter, x + y * cam.resolution.x, 0);
	thrust::uniform_real_distribution<float> u01(0, 1);

	float jitterX = u01(rng);
	float jitterY = u01(rng);

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment& segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		// TODO: implement antialiasing by jittering the ray
#if ANTIALIASING
			segment.ray.direction = glm::normalize(cam.view
				- cam.right * cam.pixelLength.x * ((float)(x + jitterX) - (float)cam.resolution.x * 0.5f)
				- cam.up * cam.pixelLength.y * ((float)(y + jitterY) - (float)cam.resolution.y * 0.5f)
			);

#else
			segment.ray.direction = glm::normalize(cam.view
				- cam.right * cam.pixelLength.x * ((float)(x) - (float)cam.resolution.x * 0.5f)
				- cam.up * cam.pixelLength.y * ((float)(y) - (float)cam.resolution.y * 0.5f)
			);
#endif

#if DOF
		float lensRadius = cam.lensRadius;
		glm::vec2 randomSample = glm::vec2(u01(rng), u01(rng));
		if (lensRadius > 0) {
			// Sample point on lens
			glm::vec2 pLens = lensRadius / 2 * concentricDiskSampling(randomSample);

			// Compute point on plane of focus
			float ft = cam.focalDist; // glm::length(cam.lookAt - cam.position);
			glm::vec3 pFocus = getPointOnRay(segment.ray, ft);

			// Update ray for effect of lens
			segment.ray.origin += pLens.x * cam.right + pLens.y * cam.up;
			//segment.ray.origin += glm::vec3(pLens.x, pLens.y, 0);
			segment.ray.direction = glm::normalize(pFocus - segment.ray.origin);
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
	, PathSegment* pathSegments
	, Geom* geoms
	, int geoms_size
	, ShadeableIntersection* intersections
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

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom& geom = geoms[i];

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
				t = objIntersectionTest(geom, geom.dev_triangles, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == IMPLICIT)
			{
				t = implicitIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
			pathSegments[path_index].remainingBounces = 0;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
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
__global__ void shadeFakeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
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
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
				pathSegments[idx].color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
				pathSegments[idx].color *= u01(rng); // apply some noise because why not
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			pathSegments[idx].color = glm::vec3(0.0f);
		}
	}
}


__global__ void shadeWithMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
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
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, pathSegments->remainingBounces);
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
			else {
				// 2. Ideal diffused shading and bounce
				// 3. Perfect specular reflection
				glm::vec3 pointOfIntersection = getPointOnRay(pathSegments[idx].ray, intersection.t);
				scatterRay(pathSegments[idx], pointOfIntersection, intersection.surfaceNormal, material, rng);
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			pathSegments[idx].color = glm::vec3(0.0f);
			pathSegments[idx].remainingBounces = 0;
		}
	}
}

__global__ void generateGBuffer(
	int num_paths,
	ShadeableIntersection* shadeableIntersections,
	PathSegment* pathSegments,
	GBufferPixel* gBuffer) {
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		gBuffer[idx].t = shadeableIntersections[idx].t;
		gBuffer[idx].pos = getPointOnRay(pathSegments[idx].ray, shadeableIntersections[idx].t);
		gBuffer[idx].nor = glm::normalize(shadeableIntersections[idx].surfaceNormal);
	}
}

__global__ void denoiser(
	int num_paths,
	int stepWidth,
	glm::ivec2 resolution,
	float cphi,
	float nphi,
	float pphi,
	glm::vec3* inputImage,
	glm::vec3* outputImage,
	GBufferPixel* gBuffer,
	float* filter,
	glm::ivec2* filterOffsets) {

	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int idx = x + (y * resolution.x);
		glm::vec2 step = 1 / resolution;
		glm::vec4 sum = glm::vec4(0.f);

		glm::vec3 cval = inputImage[idx];
		glm::vec3 pval = gBuffer[idx].pos;
		glm::vec3 nval = gBuffer[idx].nor;
		
		glm::vec3 outputColor = glm::vec3(0.f);
		float cum_w = 0.0;
		float weight = 1.f;
		//for (int stepIter = 0; stepIter < 10; stepIter++) {
		//	stepWidth = 1 << stepIter;

			for (int i = 0; i < 25; i++) {
				glm::ivec2 uv = glm::ivec2(filterOffsets[i].x * stepWidth, filterOffsets[i].y * stepWidth) + glm::ivec2(x, y);
				
				if (uv.x < resolution.x && uv.x >= 0 && uv.y < resolution.y && uv.y >= 0) {
					int idxtmp = uv.x + (uv.y * resolution.x);
					//if (idxtmp > 0 && idxtmp < num_paths) {

					glm::vec3 ctmp = inputImage[idxtmp];

#if DENOISER_EDGE_AVOIDING
					glm::vec3 t = cval - ctmp;
					float dist2 = glm::dot(t, t);
					float c_w = glm::min(glm::exp(-(dist2)/cphi), 1.f);

					glm::vec3 ntmp = gBuffer[idxtmp].nor;
					t = nval - ntmp;
					dist2 = glm::max(glm::dot(t, t)/(stepWidth * stepWidth), 0.f);
					float n_w = glm::min(glm::exp(-(dist2) / nphi), 1.f);

					glm::vec3 ptmp = gBuffer[idxtmp].pos;
					t = pval - ptmp;
					dist2 = glm::dot(t, t);
					float p_w = glm::min(glm::exp(-(dist2) / pphi), 1.f);

					weight = c_w * n_w * p_w;

#endif
					outputColor += weight * filter[i] * ctmp;
					cum_w += weight * filter[i];
				}
			}
		//}
		outputImage[idx] = outputColor/cum_w;
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

struct is_Terminated {
	__host__ __device__
		bool operator()(const PathSegment& path) {
		return path.remainingBounces;
	}
};

struct compareMaterialId {
	__host__ __device__ bool operator()(const ShadeableIntersection& isect1, const ShadeableIntersection& isect2) {
		return isect1.materialId < isect2.materialId;
	}
};


/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4* pbo, int frame, int iter, float cphi, float nphi, float pphi) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
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

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);	// iter sample number
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;	// initially number of rays cast is equal to pixel count and then it goes on decreasing after each round of stream compaction

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks
	
	int new_num_paths = num_paths;
	bool iterationComplete = false;
	while (!iterationComplete) {

		// dev_cache_intersections, set it to 0
		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (new_num_paths + blockSize1d - 1) / blockSize1d;

#if CACHEINTERSECTIONS
		if (depth == 0 && iter == 1) {
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, new_num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_cache_intersections
				);
		}
		
		if (depth == 0) {
			cudaMemcpy(dev_intersections, dev_cache_intersections, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
		}
		else {
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, new_num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				);
		}
#else
		computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
			depth
			, new_num_paths
			, dev_paths
			, dev_geoms
			, hst_scene->geoms.size()
			, dev_intersections
			);
#endif

		checkCUDAError("trace one bounce");
		cudaDeviceSynchronize();


		if (depth == 0) {
			generateGBuffer << <numblocksPathSegmentTracing, blockSize1d >> > (num_paths, dev_intersections, dev_paths, dev_gBuffer);
		}

		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
		// evaluating the BSDF.
		// Start off with just a big kernel that handles all the different
		// materials you have in the scenefile.
		// TODO: compare between directly shading the path segments and shading
		// path segments that have been reshuffled to be contiguous in memory.

#if SORTMATERIALS
		// 1. Sort ray by material
		thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + new_num_paths, dev_paths, compareMaterialId());
#endif
		// 2. Ideal diffused shading and bounce and // 3. Perfect specular reflection
		shadeWithMaterial << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			new_num_paths,
			dev_intersections,
			dev_paths,
			dev_materials
			);

		// 4. Stream compaction
		dev_path_end = thrust::partition(thrust::device, dev_paths, dev_paths + new_num_paths, is_Terminated());
		new_num_paths = dev_path_end - dev_paths;

		depth++;
		if (new_num_paths == 0){
			iterationComplete = true;
		}

		if (guiData != NULL)
		{
			guiData->TracedDepth = depth;
		}
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (num_paths, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////
#if DENOISER

	cudaMemcpy(dev_denoised_image_input, dev_image, pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToDevice);

	int stepWidth = 0;
	for (int stepIter = 0; stepIter < 5; stepIter++) {
		stepWidth = 1 << stepIter;
		denoiser << <blocksPerGrid2d, blockSize2d >> > (num_paths, stepWidth, cam.resolution, cphi, nphi, pphi, dev_denoised_image_input, dev_denoised_image_output, dev_gBuffer, dev_filter, dev_filterOffsets);
		std::swap(dev_denoised_image_input, dev_denoised_image_output);
	}
#endif
	
	// CHECKITOUT4: use dev_image as reference if you want to implement saving denoised images.
	// Otherwise, screenshots are also acceptable.
	// Retrieve image from GPU

	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}

// CHECKITOUT4: this kernel "post-processes" the gbuffer/gbuffers into something that you can visualize for debugging.
void showGBuffer(uchar4* pbo, int renderSelect) {
	const Camera& cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// CHECKITOUT: process the gbuffer results and send them to OpenGL buffer for visualization
	switch (renderSelect) {
	case DEPTH: gDepthBufferToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, dev_gBuffer);
		break;
	case NORMAL: gNormalBufferToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, dev_gBuffer);
		break;
	case POSITION: gPositionBufferToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, dev_gBuffer);
		break;
	}
	
}

void showImage(uchar4* pbo, int iter) {
	const Camera& cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);
}

void showDenoisedImage(uchar4* pbo, int iter) {
	const Camera& cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// Send results to OpenGL buffer for rendering
#if DENOISER
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_denoised_image_output);
#endif
}

