/* Copyright (c) 2018, Cyrille Favreau
 * All rights reserved. Do not distribute without permission.
 * Responsible Author: Cyrille Favreau <cyrille.favreau@gmail.com>
 *
 * This file is part of the reseach Brayns module
 * <https://github.com/favreau/Brayns-Research-Modules>
 *
 * This library is free software; you can redistribute it and/or modify it under
 * the terms of the GNU Lesser General Public License version 3.0 as published
 * by the Free Software Foundation.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

#include <common/ispc/renderer/SimulationRenderer.ih>

//#define REFRACTION
//#define VOLUME_16BITS

const float GI_OPACITY_THRESHOLD = 0.01f;
const float AMBIENT_LIGHT = 0.f; // 25f;
const float ALPHA = 2.f;
const float EPSILON = 0.001f;

struct VolumeRenderer
{
    SimulationRenderer super;

    // Rendering attributes
    const uniform Light* uniform* uniform lights;
    uint32 numLights;
    const uniform ExtendedOBJMaterial* uniform* uniform materials;
    uint32 numMaterials;
    vec3f bgColor;
    float shadows;
    bool shadingEnabled;
    float softShadows;
    float ambientOcclusionStrength;
    float ambientOcclusionDistance;
    bool electronShadingEnabled;
    int randomNumber;
    float timestamp;
    int spp;

    // Volume attributes
    uniform uint8* uniform volumeData;
    vec3i volumeDimensions;
    vec3f volumeElementSpacing;
    vec3f volumeOffset;
    float volumeEpsilon;
    float volumeDiag;
    uint32 volumeSamplesPerRay;

    // Transfer function / Color map attributes
    uniform vec4f* uniform colorMap;
    uniform vec3f* uniform emissionIntensitiesMap;
    uint32 colorMapSize;
    float colorMapMinValue;
    float colorMapRange;
    float threshold;
};

inline uniform float getEpsilon(uniform VolumeRenderer* uniform self)
{
    const uniform float spacing =
        max(self->volumeElementSpacing.x,
            max(self->volumeElementSpacing.y, self->volumeElementSpacing.z));
    const uniform float dimensions =
        max(self->volumeDimensions.x,
            max(self->volumeDimensions.y, self->volumeDimensions.z));
    return max(spacing, dimensions / self->volumeSamplesPerRay);
}

inline varying bool pointInVolume(const vec3f& point,
                                  const uniform vec3i& volume)
{
    return (point.x >= 0.f && point.x < volume.x && point.y >= 0.f &&
            point.y < volume.y && point.z >= 0.f && point.z < volume.z);
}

// AABB-Ray intersection ( http://prideout.net/blog/?p=64 ).
inline varying bool intersectBox(const uniform VolumeRenderer* uniform self,
                                 const varying Ray& ray, const vec3f& aabbMin,
                                 const vec3f& aabbMax, varying float& t0,
                                 varying float& t1)
{
    Ray r = ray;
    // We need to avoid division by zero in "vec3 invR = 1.0 / r.Dir;"
    if (r.dir.x == 0)
        r.dir.x = EPSILON;

    if (r.dir.y == 0)
        r.dir.y = EPSILON;

    if (r.dir.z == 0)
        r.dir.z = EPSILON;

    vec3f invR = 1.f / r.dir;
    vec3f tbot = invR * (aabbMin - r.org);
    vec3f ttop = invR * (aabbMax - r.org);
    vec3f tmin = min(ttop, tbot);
    vec3f tmax = max(ttop, tbot);
    vec2f t = make_vec2f(max(tmin.x, tmin.y), max(tmin.x, tmin.z));
    t0 = max(t.x, t.y);
    t = make_vec2f(min(tmax.x, tmax.y), min(tmax.x, tmax.z));
    t1 = min(t.x, t.y);
    return (t0 <= t1);
}

inline varying float getShadowContribution(
    const uniform VolumeRenderer* uniform self, const varying Ray& ray,
    varying ScreenSample& sample)
{
    // Find volume intersections
    float t0, t1;
    vec3f aabbMin = self->volumeOffset;
    vec3f aabbMax =
        make_vec3f(self->volumeOffset) +
        make_vec3f(self->volumeDimensions) * self->volumeElementSpacing;
    if (!intersectBox(self, ray, aabbMin, aabbMax, t0, t1))
        return 0.f;

    // Ray marching from light source to voxel
    const float epsilon = EPSILON;
    float shadowIntensity = 0.f;
    for (float t = t1; t > epsilon && shadowIntensity < 1.f; t -= epsilon)
    {
        const vec3f point = ray.org + ray.dir * t;
        if (pointInVolume(point, self->volumeDimensions))
        {
            uint64 index =
                (uint64)((uint64)floor(point.x) +
                         (uint64)floor(point.y) * self->volumeDimensions.x +
                         (uint64)floor(point.z) * self->volumeDimensions.x *
                             self->volumeDimensions.y);

            const uint8 voxelValue = self->volumeData[index];

            const float normalizedValue =
                self->colorMapSize * (voxelValue - self->colorMapMinValue) /
                self->colorMapRange;
            const vec4f colorMapColor = self->colorMap[normalizedValue];
            shadowIntensity += colorMapColor.w;
        }
    }
    return shadowIntensity;
}

inline float getShadowContributions(const uniform VolumeRenderer* uniform self,
                                    const varying Ray& ray,
                                    varying ScreenSample& sample,
                                    const vec3f& point)
{
    float shadowIntensity = 0.f;
    for (uniform int i = 0; self->lights && i < self->numLights; ++i)
    {
        const uniform Light* uniform light = self->lights[i];
        const varying vec2f s = make_vec2f(1.f / self->randomNumber);
        DifferentialGeometry dg;
        dg.P = point;
        const varying Light_SampleRes lightSample = light->sample(light, dg, s);

        Ray lightRay = ray;
        if (self->softShadows > 0.f)
            lightRay.dir = normalize(
                lightSample.dir +
                self->softShadows *
                    getRandomVector(self->super.super.super.fb->size.x, sample,
                                    lightSample.dir, self->randomNumber));
        else
            lightRay.dir = lightSample.dir;

        lightRay.t = length(make_vec3f(self->volumeDimensions));
        lightRay.t0 = EPSILON;
        lightRay.org = point;

        shadowIntensity += getShadowContribution(self, lightRay, sample);
    }
    return 1.f - shadowIntensity * self->shadows;
}

inline varying vec4f getVoxelColor(const uniform VolumeRenderer* uniform self,
                                   const vec3f& point)
{
    const uint64 index =
        (uint64)((uint64)floor(point.x) +
                 (uint64)floor(point.y) * self->volumeDimensions.x +
                 (uint64)floor(point.z) * self->volumeDimensions.x *
                     self->volumeDimensions.y);

// Voxel raw value
#ifdef VOLUME_16BITS
    const uint8 lo = self->volumeData[index * 2];
    const uint8 hi = self->volumeData[index * 2 + 1];
    const uint16 voxelValue = (hi * 256 + lo) / 2;
#else
    const uint8 voxelValue = self->volumeData[index];
#endif
    const float normalizedValue =
        clamp((voxelValue - self->colorMapMinValue) / self->colorMapRange, 0.f,
              1.f);

    // Colormap value
    const vec4f colorMapColor =
        self->colorMap[self->colorMapSize * normalizedValue];

    // Light emission intensity
    const vec4f emissionIntensity =
        make_vec4f(self->emissionIntensitiesMap[normalizedValue], 0.f);

    // Voxel color
    return make_vec4f(make_vec3f(emissionIntensity + colorMapColor),
                      colorMapColor.w);
}

inline varying vec4f
    getVolumeContribution(const uniform VolumeRenderer* uniform self,
                          const varying Ray& ray, varying ScreenSample& sample)
{
    const vec4f bgColor = make_vec4f(self->bgColor, 1.f);
    if (!self->colorMap)
        return bgColor;

    // Find volume intersections
    float t0, t1;
    vec3f aabbMin = self->volumeOffset;
    vec3f aabbMax =
        make_vec3f(self->volumeOffset) +
        make_vec3f(self->volumeDimensions) * self->volumeElementSpacing;
    if (!intersectBox(self, ray, aabbMin, aabbMax, t0, t1))
        return bgColor;

    // Ray marching
    t0 = max(0.f, t0);
    vec4f pathColor = make_vec4f(0.f);
    const float epsilon = EPSILON;
    const float random = getRandomValue(sample, self->randomNumber) * epsilon;
    t0 -= random;
    t1 -= random;
    float shadowContribution = 1.f;
    bool shadowProcessed = false;

    float t = t0;
    for (t = t0; t < t1 && pathColor.w < 1.f; t += epsilon)
    {
        const vec3f point = ((ray.org + ray.dir * t) - self->volumeOffset) /
                            self->volumeElementSpacing;

        if (pointInVolume(point, self->volumeDimensions))
        {
            // Voxel color
            vec4f voxelColor = getVoxelColor(self, point);

            if (self->shadows > 0.f && voxelColor.w >= GI_OPACITY_THRESHOLD &&
                !shadowProcessed)
            {
                shadowContribution =
                    getShadowContributions(self, ray, sample, point);
                shadowProcessed = true;
            }
            if (shadowContribution < 0.01f)
            {
                pathColor.w = 1.f;
                break;
            }

            // Compose final voxel color
            composite(voxelColor, pathColor, 1.f);
        }
    }

    // Z depth
    sample.z = t;

    if (shadowContribution < 1.f)
    {
        // Do not affect Alpha
        pathColor.x *= shadowContribution;
        pathColor.y *= shadowContribution;
        pathColor.z *= shadowContribution;
    }

    // Compose with background
    composite(bgColor, pathColor, 1.f);

    return pathColor;
}

inline varying vec4f getVolumeShadedContribution(
    const uniform VolumeRenderer* uniform self, const varying Ray& ray,
    varying ScreenSample& sample)
{
    const vec4f bgColor = make_vec4f(self->bgColor, 1.f);
    vec4f specularColor = make_vec4f(0.f);
    vec4f pathColor = make_vec4f(0.f);
    vec4f accColor = make_vec4f(0.f);
    const vec3f positions[15] = {{0, 0, 0},   {0, -1, 0},   {0, 1, 0},
                                 {-1, 0, 0},  {1, 0, 0},    {0, 0, 1},
                                 {0, 0, -1},  {-1, -1, -1}, {1, -1, -1},
                                 {-1, 1, -1}, {1, 1, -1},   {-1, -1, 1},
                                 {1, -1, 1},  {-1, 1, 1},   {1, 1, 1}};

    if (!self->colorMap)
        return bgColor;

    // Find volume intersections
    float t0, t1;
    vec3f aabbMin = self->volumeOffset;
    vec3f aabbMax =
        make_vec3f(self->volumeOffset) +
        make_vec3f(self->volumeDimensions) * self->volumeElementSpacing;
    if (!intersectBox(self, ray, aabbMin, aabbMax, t0, t1))
        return bgColor;

    for (int s = 0; s < self->spp; ++s)
    {
        // Ray marching
        t0 = max(0.f, t0);
        const float epsilon = self->volumeEpsilon;
        const float random = getRandomValue(sample, s) * epsilon;
        t0 -= random;
        t1 -= random;
        float shadowContribution = 1.f;
        bool shadowProcessed = false;

#ifdef REFRACTION
        float oldRefraction = 1.f;
        float T = t0;
        vec3f dir = ray.dir;
        vec3f origin = ray.org;
        vec3f oldOrigin = ray.org;
        vec3f point = ((origin + dir * t0) - self->volumeOffset) /
                      self->volumeElementSpacing;
#else
        vec3f point = ((ray.org + ray.dir * t0) - self->volumeOffset) /
                      self->volumeElementSpacing;
#endif

        float t = t0;
        for (t = t0; t < t1 && pathColor.w < 1.f; t += epsilon)
        {
            vec3f normal = make_vec3f(0.f);
            vec4f voxelColor = make_vec4f(0.f);
            unsigned int count = 1;
            float voxelOpacity = 0.f;
            vec4f colorExtrapolation = make_vec4f(0.f);
            for (int i = 0; i < 15; ++i)
            {
                const float random =
                    2.f * getRandomValue(sample, self->randomNumber);
                const vec3f neighbour =
                    ((ray.org +
                      positions[i] * self->volumeElementSpacing * random +
                      ray.dir * t) -
                     self->volumeOffset) /
                    self->volumeElementSpacing;

                if (pointInVolume(neighbour, self->volumeDimensions))
                {
                    // Voxel color
                    const vec4f color = getVoxelColor(self, neighbour);

                    if (i == 0)
                    {
                        voxelColor = color;
                        voxelOpacity = color.w;

                        if (color.w > 0.99f)
                            sample.z = t;
                        if (color.w < GI_OPACITY_THRESHOLD)
                            break;
                    }

                    colorExtrapolation = colorExtrapolation + color;

                    // Normal
                    normal = normal + positions[i] * (1.f - color.w);
                }
                else
                    normal = normal + positions[i];
                ++count;
            }

            voxelColor =
                make_vec4f(ALPHA * make_vec3f(colorExtrapolation) / count,
                           voxelColor.w);

            normal = normalize(normal);
            voxelColor.w = voxelOpacity;

            // Shadows
            if (self->shadows > 0.f && voxelColor.w >= GI_OPACITY_THRESHOLD &&
                !shadowProcessed)
            {
                shadowContribution =
                    getShadowContributions(self, ray, sample, point);
                shadowProcessed = true;
            }
            if (shadowContribution < 0.01f)
            {
                pathColor.w = 1.f;
                break;
            }

            if (voxelColor.w >= GI_OPACITY_THRESHOLD)
            {
                float angle;
                if (self->electronShadingEnabled)
                    angle = 1.f - max(0.f, dot(neg(ray.dir), normal));
                else
                {
                    // Shading according to computed normal
                    for (uniform int i = 0; self->lights && i < self->numLights;
                         ++i)
                    {
                        const uniform Light* uniform light = self->lights[i];
                        const vec2f s = make_vec2f(0.5f);
                        DifferentialGeometry dg;
                        dg.P = point;
                        const varying Light_SampleRes lightSample =
                            light->sample(light, dg, s);
                        const vec3f radiance = lightSample.weight;
                        const vec3f lightDirection = lightSample.dir;

                        // Diffuse
                        angle = max(0.f, dot(lightDirection, normal));

                        // Specular
                        const vec3f reflectedNormal = normalize(
                            ray.dir - 2.f * dot(ray.dir, normal) * normal);
                        const float specularAngle =
                            powf(max(0.f, dot(lightDirection, reflectedNormal)),
                                 20.f);
                        angle = max(angle, specularAngle);
                        specularColor =
                            make_vec4f(0.5f * make_vec3f(specularAngle), 0.f);
                    }
                }

                // Do not affect Alpha
                voxelColor.x = voxelColor.x * angle;
                voxelColor.y = voxelColor.y * angle;
                voxelColor.z = voxelColor.z * angle;
            }

#ifdef REFRACTION
            // Refraction
            const float refraction =
                (voxelColor.w > 0.f
                     ? 1.f + self->ambientOcclusionStrength * 0.25f
                     : 1.f);
            if (abs(refraction - oldRefraction) > 0.001f)
            {
                origin = oldOrigin + dir * T;
                T = 0.f;
                oldOrigin = origin;
                dir = refractedVector(dir, normalize(normal), oldRefraction,
                                      refraction);
            }
            oldRefraction = refraction;

            T += epsilon;
            point = ((origin + dir * T) - self->volumeOffset) /
                    self->volumeElementSpacing;
#else
            point = ((ray.org + ray.dir * t) - self->volumeOffset) /
                    self->volumeElementSpacing;
#endif

            // Compose final voxel color
            composite(voxelColor, pathColor, 1.f);
        }

        // Ambient light
        shadowContribution =
            clamp(shadowContribution + AMBIENT_LIGHT, 0.f, 1.f);
        pathColor.x *= shadowContribution;
        pathColor.y *= shadowContribution;
        pathColor.z *= shadowContribution;

        if (shadowContribution > 0.9f)
        {
            // Specular color
            pathColor.x = max(pathColor.x, specularColor.x);
            pathColor.y = max(pathColor.y, specularColor.y);
            pathColor.z = max(pathColor.z, specularColor.z);
        }

        // Compose with background
        composite(bgColor, pathColor, 1.f);

        accColor = accColor + pathColor;
    }
    return accColor / self->spp;
}

inline vec3f VolumeRenderer_shadeRay(const uniform VolumeRenderer* uniform self,
                                     varying ScreenSample& sample)
{
    Ray ray = sample.ray;
    vec4f color = make_vec4f(self->bgColor, 0.f);

    sample.z = inf;

    // Trace ray
    traceRay(self->super.super.super.model, ray);

    // Volume contribution
    if (self->volumeData)
        color = (self->shadingEnabled || self->electronShadingEnabled)
                    ? getVolumeShadedContribution(self, ray, sample)
                    : getVolumeContribution(self, ray, sample);

    sample.alpha = color.w;
    return make_vec3f(color);
}

void VolumeRenderer_renderSample(uniform Renderer* uniform _self,
                                 void* uniform perFrameData,
                                 varying ScreenSample& sample)
{
    uniform VolumeRenderer* uniform self =
        (uniform VolumeRenderer * uniform)_self;
    sample.ray.time = self->timestamp;
    sample.rgb = VolumeRenderer_shadeRay(self, sample);
}

// Exports (called from C++)
export void* uniform VolumeRenderer_create(void* uniform cppE)
{
    uniform VolumeRenderer* uniform self = uniform new uniform VolumeRenderer;
    Renderer_Constructor(&self->super.super.super, cppE);
    self->super.super.super.renderSample = VolumeRenderer_renderSample;
    return self;
}

export void VolumeRenderer_set(
    void* uniform _self, const uniform vec3f& bgColor,
    const uniform float& shadows, const uniform float& softShadows,
    const uniform float& ambientOcclusionStrength,
    const uniform float& ambientOcclusionDistance,
    const uniform bool& shadingEnabled, const uniform int& randomNumber,
    const uniform float& timestamp, const uniform int& spp,
    const uniform bool& electronShadingEnabled, void** uniform lights,
    const uniform int32 numLights, void** uniform materials,
    const uniform int32 numMaterials, uniform uint8* uniform volumeData,
    const uniform vec3i& volumeDimensions,
    const uniform vec3f& volumeElementSpacing,
    const uniform vec3f& volumeOffset, const uniform float& volumeEpsilon,
    const uniform int32& volumeSamplesPerRay, uniform vec4f* uniform colormap,
    uniform vec3f* uniform emissionIntensitiesMap,
    const uniform int32 colorMapSize, const uniform float& colorMapMinValue,
    const uniform float& colorMapRange, const uniform float& threshold)
{
    uniform VolumeRenderer* uniform self =
        (uniform VolumeRenderer * uniform)_self;

    self->bgColor = bgColor;
    self->shadows = shadows;
    self->softShadows = softShadows;
    self->ambientOcclusionStrength = ambientOcclusionStrength;
    self->ambientOcclusionDistance = ambientOcclusionDistance;
    self->shadingEnabled = shadingEnabled;
    self->randomNumber = randomNumber;
    self->timestamp = timestamp;
    self->spp = spp;
    self->electronShadingEnabled = electronShadingEnabled;

    self->lights = (const uniform Light* uniform* uniform)lights;
    self->numLights = numLights;

    self->materials =
        (const uniform ExtendedOBJMaterial* uniform* uniform)materials;
    self->numMaterials = numMaterials;

    self->volumeData = (uniform uint8 * uniform)volumeData;
    self->volumeDimensions = volumeDimensions;
    self->volumeElementSpacing = volumeElementSpacing;
    self->volumeOffset = volumeOffset;
    self->volumeEpsilon = getEpsilon(self);
    self->volumeSamplesPerRay = volumeSamplesPerRay;

    const uniform vec3f diag =
        make_vec3f(volumeDimensions) * volumeElementSpacing;
    self->volumeDiag = max(diag.x, max(diag.y, diag.z));

    self->colorMap = (uniform vec4f * uniform)colormap;
    self->emissionIntensitiesMap =
        (uniform vec3f * uniform)emissionIntensitiesMap;
    self->colorMapSize = colorMapSize;
    self->colorMapMinValue = colorMapMinValue;
    self->colorMapRange = colorMapRange;

    self->threshold = threshold;
}
