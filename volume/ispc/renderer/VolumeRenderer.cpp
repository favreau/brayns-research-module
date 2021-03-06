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

#include "VolumeRenderer.h"

// ospray
#include <ospray/SDK/common/Data.h>
#include <ospray/SDK/lights/Light.h>

// ispc exports
#include "VolumeRenderer_ispc.h"

using namespace ospray;

namespace brayns
{
void VolumeRenderer::commit()
{
    Renderer::commit();

    _lightData = (ospray::Data*)getParamData("lights");
    _lightArray.clear();

    if (_lightData)
        for (size_t i = 0; i < _lightData->size(); ++i)
            _lightArray.push_back(
                ((ospray::Light**)_lightData->data)[i]->getIE());

    _lightPtr = _lightArray.empty() ? nullptr : &_lightArray[0];

    _bgColor = getParam3f("bgColor", ospray::vec3f(1.f));
    _shadows = getParam1f("shadows", 0.f);
    _softShadows = getParam1f("softShadows", 0.f);
    _ambientOcclusionStrength = getParam1f("aoWeight", 0.f);
    _ambientOcclusionDistance = getParam1f("aoDistance", 1e20f);
    _shadingEnabled = bool(getParam1i("shadingEnabled", 1));
    _randomNumber = getParam1i("randomNumber", 0);
    _timestamp = getParam1f("timestamp", 0.f);
    _spp = getParam1i("spp", 1);
    _electronShadingEnabled = bool(getParam1i("electronShading", 0));

    // Those materials are used for simulation mapping only
    _materialData = (ospray::Data*)getParamData("materials");
    _materialArray.clear();
    if (_materialData)
        for (size_t i = 0; i < _materialData->size(); ++i)
            _materialArray.push_back(
                ((ospray::Material**)_materialData->data)[i]->getIE());
    _materialPtr = _materialArray.empty() ? nullptr : &_materialArray[0];

    // Volume
    _volumeData = getParamData("volumeData");
    _volumeDimensions = getParam3i("volumeDimensions", ospray::vec3i(0));
    _volumeElementSpacing =
        getParam3f("volumeElementSpacing", ospray::vec3f(1.f));
    _volumeOffset = getParam3f("volumeOffset", ospray::vec3f(0.f));
    _volumeEpsilon = getParam1f("volumeEpsilon", 1.f);
    _volumeSamplesPerRay = getParam1i("volumeSamplesPerRay", 32);

    // Transfer function
    _transferFunctionDiffuseData = getParamData("transferFunctionDiffuseData");
    _transferFunctionEmissionData =
        getParamData("transferFunctionEmissionData");
    _transferFunctionSize = getParam1i("transferFunctionSize", 0);
    _transferFunctionMinValue = getParam1f("transferFunctionMinValue", 0.f);
    _transferFunctionRange = getParam1f("transferFunctionRange", 0.f);
    _threshold = getParam1f("threshold", _transferFunctionMinValue);

    ispc::VolumeRenderer_set(
        getIE(), (ispc::vec3f&)_bgColor, _shadows, _softShadows,
        _ambientOcclusionStrength, _ambientOcclusionDistance, _shadingEnabled,
        _randomNumber, _timestamp, _spp, _electronShadingEnabled, _lightPtr,
        _lightArray.size(), _materialPtr, _materialArray.size(),
        _volumeData ? (uint8*)_volumeData->data : NULL,
        (ispc::vec3i&)_volumeDimensions, (ispc::vec3f&)_volumeElementSpacing,
        (ispc::vec3f&)_volumeOffset, _volumeEpsilon, _volumeSamplesPerRay,
        _transferFunctionDiffuseData
            ? (ispc::vec4f*)_transferFunctionDiffuseData->data
            : NULL,
        _transferFunctionEmissionData
            ? (ispc::vec3f*)_transferFunctionEmissionData->data
            : NULL,
        _transferFunctionSize, _transferFunctionMinValue,
        _transferFunctionRange, _threshold);
}

VolumeRenderer::VolumeRenderer()
{
    ispcEquivalent = ispc::VolumeRenderer_create(this);
}

OSP_REGISTER_RENDERER(VolumeRenderer, research_volume);
} // namespace brayns
