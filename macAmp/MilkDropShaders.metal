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
    int style = int(clamp(floor(uniforms.preset4.y + 0.5), 0.0, 5.0));

    float2 centered = input.uv - 0.5;
    float radius = length(centered);
    float audioPulse = bass * 0.65 + mid * 0.25 + treble * 0.1;
    float angle = rotationSpeed * time + uniforms.visual.x
        + sin(time * (0.42 + pulseAmount * 0.14) + radius * (7.0 + radialAmount * 15.0))
            * (warpStrength * (0.35 + mid));
    float c = cos(angle);
    float s = sin(angle);
    float2 warped = float2(centered.x * c - centered.y * s,
                           centered.x * s + centered.y * c);
    warped *= zoom + sin(time * (0.31 + pulseAmount * 0.1)) * warpStrength * 0.08;
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
    float emission = (0.08 + volume * 0.34) * brightness;
    float3 source = float3(0.0);

    if (style == 0) {
        // Orbit: narrow concentric rings, driven mostly by the low end.
        float ringPhase = fract(radius * (5.5 + radialAmount * 9.0)
                                - time * (0.16 + pulseAmount * 0.36) - bass * 0.2);
        float ring = 1.0 - smoothstep(0.035, 0.09, abs(ringPhase - 0.5));
        source += primary * ring * (0.32 + audioPulse * glowAmount);
    } else if (style == 1) {
        // Nebula: two moving fields make a cloud rather than a bright fill.
        float cloud = sin(centered.x * 18.0 + time * 0.31)
                    * sin(centered.y * 13.0 - time * 0.23)
                    + sin((centered.x + centered.y) * 10.0 + time * 0.17);
        float nebula = smoothstep(1.15, 1.75, cloud);
        source += mix(primary, secondary, 0.55) * nebula * (0.22 + audioPulse * glowAmount);
    } else if (style == 2) {
        // Kaleidoscope: sharp mirrored diagonal shards.
        float2 mirror = abs(centered);
        float diagonal = abs(fract((mirror.x + mirror.y * 1.7) * symmetry * 4.0
                                   - time * 0.17) - 0.5);
        float shards = 1.0 - smoothstep(0.025, 0.085, diagonal);
        source += primary * shards * (0.26 + audioPulse * glowAmount);
    } else if (style == 3) {
        // Spectrum: draw only the one column associated with this fragment.
        int band = clamp(int(input.uv.x * 16.0), 0, 15);
        float level = spectrumAt(uniforms, band);
        float centerX = (float(band) + 0.5) / 16.0;
        float column = 1.0 - smoothstep(0.015, 0.035, abs(input.uv.x - centerX));
        float height = 0.08 + level * 0.72 * spectrumGain;
        float body = column * step(input.uv.y, height);
        float cap = column * (1.0 - smoothstep(0.004, 0.018, abs(input.uv.y - height)));
        source += primary * (body * 0.28 + cap * (0.55 + treble * glowAmount));
    } else if (style == 4) {
        // Ribbons: a few wide bands whose displacement reacts to the midrange.
        float ribbonY = 0.5 + sin(input.uv.x * (7.0 + radialAmount * 12.0)
                                   + time * (0.5 + pulseAmount * 0.4))
            * (0.05 + mid * 0.16);
        float ribbon = 1.0 - smoothstep(0.009, 0.04 + waveformGain * 0.012,
                                         abs(input.uv.y - ribbonY));
        source += mix(primary, secondary, input.uv.x) * ribbon * (0.25 + audioPulse * glowAmount);
    } else {
        // Tunnel: a moving perspective grid of shrinking rings.
        float tunnel = fract(radius * (5.0 + radialAmount * 14.0)
                             - time * (0.28 + pulseAmount * 0.52));
        float ring = 1.0 - smoothstep(0.025, 0.075, abs(tunnel - 0.5));
        float ray = 1.0 - smoothstep(0.02, 0.075,
                                     abs(abs(centered.x) - abs(centered.y) * 0.65));
        source += primary * (ring * 0.27 + ray * 0.1) * (0.28 + audioPulse * glowAmount);
    }

    // A compact spectrum accent is shared by all presets. Unlike the former
    // 16-column loop, every pixel reads just one FFT bucket.
    int accentBand = clamp(int(input.uv.x * 16.0), 0, 15);
    float accentLevel = spectrumAt(uniforms, accentBand);
    float accentX = (float(accentBand) + 0.5) / 16.0;
    float accent = (1.0 - smoothstep(0.02, 0.045, abs(input.uv.x - accentX)))
        * (1.0 - smoothstep(0.005, 0.02, abs(input.uv.y - 0.92)));
    source += secondary * accent * accentLevel * spectrumGain * 0.22;

    float centre = exp(-radius * 18.0) * (0.025 + bass * (0.12 + glowAmount * 0.22));
    source += primary * centre;

    float3 color = previous * decay + source * emission;
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
