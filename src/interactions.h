#pragma once

#include "intersections.h"

// CHECKITOUT
/**
 * Computes a cosine-weighted random direction in a hemisphere.
 * Used for diffuse lighting.
 */
__host__ __device__
glm::vec3 calculateRandomDirectionInHemisphere(
        glm::vec3 normal, thrust::default_random_engine &rng) {
    thrust::uniform_real_distribution<float> u01(0, 1);

    float up = sqrt(u01(rng)); // cos(theta)
    float over = sqrt(1 - up * up); // sin(theta)
    float around = u01(rng) * TWO_PI;

    // Find a direction that is not the normal based off of whether or not the
    // normal's components are all equal to sqrt(1/3) or whether or not at
    // least one component is less than sqrt(1/3). Learned this trick from
    // Peter Kutz.

    glm::vec3 directionNotNormal;
    if (abs(normal.x) < SQRT_OF_ONE_THIRD) {
        directionNotNormal = glm::vec3(1, 0, 0);
    } else if (abs(normal.y) < SQRT_OF_ONE_THIRD) {
        directionNotNormal = glm::vec3(0, 1, 0);
    } else {
        directionNotNormal = glm::vec3(0, 0, 1);
    }

    // Use not-normal direction to generate two perpendicular directions
    glm::vec3 perpendicularDirection1 =
        glm::normalize(glm::cross(normal, directionNotNormal));
    glm::vec3 perpendicularDirection2 =
        glm::normalize(glm::cross(normal, perpendicularDirection1));

    return up * normal
        + cos(around) * over * perpendicularDirection1
        + sin(around) * over * perpendicularDirection2;
}

/**
 * Scatter a ray with some probabilities according to the material properties.
 * For example, a diffuse surface scatters in a cosine-weighted hemisphere.
 * A perfect specular surface scatters in the reflected ray direction.
 * In order to apply multiple effects to one surface, probabilistically choose
 * between them.
 *
 * The visual effect you want is to straight-up add the diffuse and specular
 * components. You can do this in a few ways. This logic also applies to
 * combining other types of materias (such as refractive).
 *
 * - Always take an even (50/50) split between a each effect (a diffuse bounce
 *   and a specular bounce), but divide the resulting color of either branch
 *   by its probability (0.5), to counteract the chance (0.5) of the branch
 *   being taken.
 *   - This way is inefficient, but serves as a good starting point - it
 *     converges slowly, especially for pure-diffuse or pure-specular.
 * - Pick the split based on the intensity of each material color, and divide
 *   branch result by that branch's probability (whatever probability you use).
 *
 * This method applies its changes to the Ray parameter `ray` in place.
 * It also modifies the color `color` of the ray in place.
 *
 * You may need to change the parameter list for your purposes!
 */
__host__ __device__
void scatterRay(    // similar to sample_f, calculate the new wi and f
    PathSegment& pathSegment,
    glm::vec3 intersect,
    glm::vec3 normal,
    const Material& m,
    thrust::default_random_engine& rng) {
    // TODO: implement this.
    // A basic implementation of pure-diffuse shading will just call the
    // calculateRandomDirectionInHemisphere defined above.
    if (pathSegment.remainingBounces == 0) {
        return;
    }

    glm::vec3 wi_scatteredRayDir = glm::vec3(0.f, 0.f, 0.f);
    glm::vec3 wo = pathSegment.ray.direction;
    glm::vec3 color = m.color;
    float airIOR = 1.0f;
    float eta = m.indexOfRefraction / airIOR;

    thrust::uniform_real_distribution<float> u01(0, 1);
    float random = u01(rng);

    //float etaA = 1.f;
    //float etaB = m.indexOfRefraction;


    if (random <= m.hasReflective) {
        wi_scatteredRayDir = glm::reflect(wo, normal);
        color = m.specular.color * m.color * m.hasReflective;
    }
    else if (random <= m.hasReflective + m.hasRefractive) {
        float cosTheta = glm::dot(glm::normalize(wo), normal);

        bool entering = cosTheta > 0;
        eta = entering ? m.indexOfRefraction : 1.f / m.indexOfRefraction;

        float sinThetaI = sqrt(1 - pow(cosTheta, 2));
        float sinThetaT = eta * sinThetaI;

        if (sinThetaT > 1) {
            wi_scatteredRayDir = glm::normalize(glm::reflect(glm::normalize(wo), normal));
        }
        else {
            wi_scatteredRayDir = glm::normalize(glm::refract(glm::normalize(wo), normal, eta));
        }
        color = m.specular.color;
        //intersect += 0.001f * glm::normalize(wi_scatteredRayDir);
        //bool entering = (glm::dot(wo, normal) > 0);
        //float etaI = entering ? etaA : etaB;
        //float etaT = entering ? etaB : etaA;
        //wi_scatteredRayDir = glm::normalize(glm::reframe ct(wo, normal, etaT / etaI));
    }
    // if costheta(eta) > 1, then reflect dir about normal else refract, set new color to current color * specular color
    else {
        wi_scatteredRayDir = calculateRandomDirectionInHemisphere(normal, rng);  // for pure diffused material
    }

    pathSegment.ray.direction = wi_scatteredRayDir;
    pathSegment.ray.origin = intersect + 0.001f * glm::normalize(wi_scatteredRayDir);
    pathSegment.color *= color;
    pathSegment.remainingBounces--;
}