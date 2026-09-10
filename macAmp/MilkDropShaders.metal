#include <metal_stdlib>

using namespace metal;

struct FullscreenVertex {
    float2 position;
    float2 uv;
};

struct WaveVertex {
    float2 position;
    float4 color;
};

struct Uniforms {
    float4 timeDelta;
    float4 audio;
    float4 visual;
    float4 spectrum0;
    float4 spectrum1;
    float4 spectrum2;
    float4 spectrum3;
    float4 preset0;
    float4 preset1;
    float4 preset2;
    float4 preset3;
    float4 preset4;
};

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

struct WaveOut {
    float4 position [[position]];
    float4 color;
};

vertex FullscreenOut milkDropFullscreenVertex(
    uint vertexID [[vertex_id]],
    const device FullscreenVertex *vertices [[buffer(0)]]) {
    FullscreenOut output;
    output.position = float4(vertices[vertexID].position, 0.0, 1.0);
    output.uv = vertices[vertexID].uv;
    return output;
}

float spectrumAt(constant Uniforms &uniforms, int index) {
    if (index < 4) {
        return uniforms.spectrum0[index];
    }
    if (index < 8) {
        return uniforms.spectrum1[index - 4];
    }
    if (index < 12) {
        return uniforms.spectrum2[index - 8];
    }
    return uniforms.spectrum3[index - 12];
}

float3 hsvToRGB(float3 hsv) {
    float3 p = abs(fract(hsv.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return hsv.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), hsv.y);
}

fragment half4 milkDropFeedback(
    FullscreenOut input [[stage_in]],
    texture2d<half> history [[texture(0)]],
    sampler historySampler [[sampler(0)]],
    constant Uniforms &uniforms [[buffer(0)]]) {
    float time = uniforms.timeDelta.x;
    float bass = uniforms.timeDelta.z;
    float mid = uniforms.timeDelta.w;
    float treble = uniforms.audio.x;
    float volume = uniforms.audio.y;
    float beat = uniforms.audio.z;
    float waveformEnergy = uniforms.audio.w;
    float warpStrength = uniforms.preset0.x;
    float rotationSpeed = uniforms.preset0.y;
    float zoom = uniforms.preset0.z;
    float hueSpeed = uniforms.preset0.w;
    float2 drift = uniforms.preset1.xy;
    float hueOffset = uniforms.preset1.z;
    float saturation = uniforms.preset1.w;
    float brightness = uniforms.preset2.x;
    float radialAmount = uniforms.preset2.y;
    float spectrumGain = uniforms.preset2.z;
    float waveformGain = uniforms.preset2.w;
    float decay = uniforms.preset3.x;
    float glowAmount = uniforms.preset3.y;
    float pulseAmount = uniforms.preset3.z;
    float symmetry = max(1.0, uniforms.preset4.x);
    int style = int(clamp(floor(uniforms.preset4.y + 0.5), 0.0, 10.0));

    float2 centered = input.uv - 0.5;
    float radius = length(centered);
    float audioPulse = min(1.5, bass * 0.42 + mid * 0.2 + treble * 0.08
                                + waveformEnergy * 0.25 + beat * 0.9);
    float angle = rotationSpeed * time + uniforms.visual.x
        + sin(time * (0.42 + pulseAmount * 0.14) + radius * (7.0 + radialAmount * 15.0))
            * (warpStrength * (0.35 + mid));
    float c = cos(angle);
    float s = sin(angle);
    float2 warped = float2(centered.x * c - centered.y * s,
                           centered.x * s + centered.y * c);
    warped *= zoom + sin(time * (0.31 + pulseAmount * 0.1)) * warpStrength * 0.08
        - beat * warpStrength * 0.42;
    warped += drift * time + float2(sin(time * 0.17), cos(time * 0.13))
        * (warpStrength * (0.12 + bass * 0.18));

    // A cheap mirror fold creates the kaleidoscope family without the atan2
    // and per-pixel trigonometry of a full polar transform.
    if (style == 2) {
        float2 folded = abs(warped);
        warped = fract(folded * symmetry) / symmetry - 0.5 / symmetry;
    }

    float3 previous = float3(history.sample(historySampler, fract(warped + 0.5)).rgb);
    float hue = fract(hueOffset + hueSpeed * time + radius * (0.1 + radialAmount * 0.22));
    float3 primary = hsvToRGB(float3(hue, saturation, 1.0));
    float3 secondary = hsvToRGB(float3(fract(hue + 0.22), saturation * 0.82, 1.0));
    // Keep the backdrop black, but make the narrow generated forms visible
    // even when the analyser reports a quiet passage.
    float emission = (0.08 + volume * 0.34) * brightness * (1.0 + beat * 0.7);
    float3 source = float3(0.0);

    if (style == 0) {
        // Orbit: narrow concentric rings, driven mostly by the low end.
        float ringPhase = fract(radius * (5.5 + radialAmount * 9.0)
                                - time * (0.16 + pulseAmount * 0.36)
                                - bass * 0.2 - beat * 0.22);
        float ring = 1.0 - smoothstep(0.035, 0.09, abs(ringPhase - 0.5));
        source += primary * ring * (0.32 + audioPulse * glowAmount);
    } else if (style == 1) {
        // Nebula: two moving fields make a cloud rather than a bright fill.
        float cloud = sin(centered.x * 18.0 + time * 0.31)
                    * sin(centered.y * 13.0 - time * 0.23)
                    + sin((centered.x + centered.y) * 10.0 + time * 0.17);
        float nebula = smoothstep(1.15 - beat * 0.18, 1.75, cloud);
        source += mix(primary, secondary, 0.55) * nebula * (0.22 + audioPulse * glowAmount);
    } else if (style == 2) {
        // Kaleidoscope: sharp mirrored diagonal shards.
        float2 mirror = abs(centered);
        float diagonal = abs(fract((mirror.x + mirror.y * 1.7) * symmetry * 4.0
                                   - time * 0.17 - beat * 0.16) - 0.5);
        float shards = 1.0 - smoothstep(0.025, 0.085, diagonal);
        source += primary * shards * (0.26 + audioPulse * glowAmount);
    } else if (style == 3) {
        // Spectrum: draw only the one column associated with this fragment.
        int band = clamp(int(input.uv.x * 16.0), 0, 15);
        float level = spectrumAt(uniforms, band);
        float centerX = (float(band) + 0.5) / 16.0;
        float column = 1.0 - smoothstep(0.015, 0.035, abs(input.uv.x - centerX));
        float height = 0.08 + level * 0.66 * spectrumGain + beat * 0.08;
        float body = column * step(input.uv.y, height);
        float cap = column * (1.0 - smoothstep(0.004, 0.018, abs(input.uv.y - height)));
        source += primary * (body * 0.28 + cap * (0.55 + treble * glowAmount));
    } else if (style == 4) {
        // Ribbons: a few wide bands whose displacement reacts to the midrange.
        float ribbonY = 0.5 + sin(input.uv.x * (7.0 + radialAmount * 12.0)
                                   + time * (0.5 + pulseAmount * 0.4) + beat * 1.4)
            * (0.045 + mid * 0.13 + waveformEnergy * 0.22 + beat * 0.06);
        float ribbon = 1.0 - smoothstep(0.009, 0.04 + waveformGain * 0.012,
                                         abs(input.uv.y - ribbonY));
        source += mix(primary, secondary, input.uv.x) * ribbon * (0.25 + audioPulse * glowAmount);
    } else if (style == 5) {
        // Tunnel: a moving perspective grid of shrinking rings.
        float tunnel = fract(radius * (5.0 + radialAmount * 14.0)
                             - time * (0.28 + pulseAmount * 0.52) - beat * 0.28);
        float ring = 1.0 - smoothstep(0.025, 0.075, abs(tunnel - 0.5));
        float ray = 1.0 - smoothstep(0.02, 0.075,
                                     abs(abs(centered.x) - abs(centered.y) * 0.65));
        source += primary * (ring * 0.27 + ray * 0.1) * (0.28 + audioPulse * glowAmount);
    } else if (style == 6) {
        // Plasma: three low-cost moving fields create a shader-like colour
        // surface while the threshold keeps most of the backdrop black.
        float fieldA = sin(centered.x * 11.0 + time * (0.36 + mid * 0.22))
                     + sin(centered.y * 14.0 - time * 0.27)
                     + sin((centered.x + centered.y) * 9.0 + time * 0.19);
        float fieldB = sin(length(centered) * (18.0 + radialAmount * 12.0)
                            - time * (0.55 + bass * 0.4));
        float plasma = smoothstep(1.0 - beat * 0.3, 2.35, fieldA + fieldB * 0.5);
        source += mix(primary, secondary, plasma) * plasma
            * (0.18 + audioPulse * glowAmount * 0.72);
    } else if (style == 7) {
        // Starburst: narrow angular rays and a bass-reactive centre. atan2 is
        // used once per pixel and avoids allocating any particle geometry.
        float angle = atan2(centered.y, centered.x);
        float rays = abs(sin(angle * (10.0 + symmetry * 4.0)
                          + time * (0.42 + pulseAmount * 0.3)));
        float rayMask = 1.0 - smoothstep(0.72, 0.98, rays);
        float radialFade = 1.0 - smoothstep(0.12, 0.82, radius);
        float burst = rayMask * radialFade * (0.24 + bass * 0.86 + beat * 0.55);
        source += mix(primary, secondary, rayMask) * burst;
    } else if (style == 8) {
        // Liquid: overlapping signed fields form soft blobs that drift with
        // the midrange and leave a coloured feedback trace.
        float liquidA = sin(centered.x * 8.0 + sin(time * 0.31) * 3.0)
                      + cos(centered.y * 10.0 - time * 0.24);
        float liquidB = sin((centered.x - centered.y) * 12.0 + time * 0.18)
                      + cos(length(centered) * 21.0 - time * 0.42);
        float blobs = smoothstep(0.55 - mid * 0.35 - beat * 0.2, 1.85,
                                 liquidA + liquidB * 0.42);
        source += mix(secondary, primary, blobs) * blobs
            * (0.16 + audioPulse * glowAmount * 0.68);
    } else if (style == 9) {
        // Spiral: polar bands are phase-shifted by radius to produce a
        // twisting vortex. The central glow prevents the spiral from vanishing
        // during quiet passages.
        float angle = atan2(centered.y, centered.x);
        float spiralPhase = angle * (3.0 + radialAmount * 5.0)
            + radius * (24.0 + radialAmount * 18.0)
            - time * (0.75 + pulseAmount * 0.55) - beat * 0.9;
        float spiral = 1.0 - smoothstep(0.32, 0.92, abs(sin(spiralPhase)));
        float spiralFade = 1.0 - smoothstep(0.08, 0.84, radius);
        source += mix(primary, secondary, fract(radius * 2.8 + time * 0.04))
            * spiral * spiralFade * (0.18 + audioPulse * glowAmount * 0.72);
    } else {
        // Grid: a sparse geometric field with audio-driven line thickness.
        float gridX = abs(fract((input.uv.x + drift.x * time) * (7.0 + radialAmount * 5.0)) - 0.5);
        float gridY = abs(fract((input.uv.y + drift.y * time) * (5.0 + pulseAmount * 4.0)) - 0.5);
        float lineWidth = 0.045 + beat * 0.045 + volume * 0.025;
        float grid = 1.0 - smoothstep(lineWidth, lineWidth + 0.035,
                                      min(gridX, gridY));
        float diagonal = 1.0 - smoothstep(0.018, 0.055,
                                           abs(fract((input.uv.x + input.uv.y) * 4.0
                                                     - time * 0.08) - 0.5));
        source += mix(primary, secondary, diagonal) * (grid * 0.15 + diagonal * 0.07)
            * (0.24 + audioPulse * glowAmount * 0.62);
    }

    // A compact spectrum accent is shared by all presets. Unlike the former
    // 16-column loop, every pixel reads just one FFT bucket.
    int accentBand = clamp(int(input.uv.x * 16.0), 0, 15);
    float accentLevel = spectrumAt(uniforms, accentBand);
    float accentX = (float(accentBand) + 0.5) / 16.0;
    float accent = (1.0 - smoothstep(0.02, 0.045, abs(input.uv.x - accentX)))
        * (1.0 - smoothstep(0.005, 0.02, abs(input.uv.y - 0.92)));
    source += secondary * accent * accentLevel * spectrumGain * 0.22;

    float centre = exp(-radius * 18.0)
        * (0.025 + bass * (0.12 + glowAmount * 0.22) + beat * 0.32);
    source += primary * centre;

    float3 color = previous * max(0.86, decay - beat * 0.025) + source * emission;
    // Compress only the top end. This preserves dark space around the effect
    // while preventing long feedback trails from becoming a white rectangle.
    color = color / (1.0 + max(color - 0.72, float3(0.0)) * 1.8);
    return half4(half3(clamp(color, 0.0, 1.0)), 1.0h);
}

fragment half4 milkDropPresent(
    FullscreenOut input [[stage_in]],
    texture2d<half> image [[texture(0)]],
    sampler imageSampler [[sampler(0)]]) {
    return image.sample(imageSampler, input.uv);
}

vertex WaveOut milkDropWaveVertex(
    uint vertexID [[vertex_id]],
    const device WaveVertex *vertices [[buffer(0)]]) {
    WaveOut output;
    output.position = float4(vertices[vertexID].position, 0.0, 1.0);
    output.color = vertices[vertexID].color;
    return output;
}

fragment half4 milkDropWaveFragment(WaveOut input [[stage_in]]) {
    return half4(input.color);
}
