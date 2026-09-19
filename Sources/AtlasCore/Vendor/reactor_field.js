// "Celestial Transmutation" particle field by VoXelo (CodePen: yygKOVy).
// Vendored and used as the ATLAS HUD background. Their code is otherwise
// unmodified; the only change is one line letting voice loudness drive
// uTransitionEnergy. three.js and its addons are vendored under vendor/three
// so the HUD works with no network.

import * as THREE from 'three';
    import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
    import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
    import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
    import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
    import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';

    const PLANETS = [
        {
            name: 'Aethera',
            kicker: 'Oceanic dreamworld',
            description: 'A luminous water planet whose equatorial currents fold into violet auroras and suspended atmospheric rivers.',
            accentA: '84, 226, 255',
            accentB: '160, 88, 255'
        },
        {
            name: 'Pyra',
            kicker: 'Living furnace world',
            description: 'A carbon-black planet split by molten tectonic calligraphy, with incandescent matter breathing through every fracture.',
            accentA: '255, 132, 44',
            accentB: '255, 45, 86'
        },
        {
            name: 'Orison',
            kicker: 'Sacred ring architecture',
            description: 'A pearl-and-teal giant encircled by a vast luminous archive: billions of particles arranged like celestial sheet music.',
            accentA: '255, 220, 142',
            accentB: '74, 232, 210'
        },
        {
            name: 'Vesper',
            kicker: 'Crystalline night engine',
            description: 'A faceted violet world that stores starlight inside geometric continents and releases it through cyan polar seams.',
            accentA: '177, 116, 255',
            accentB: '76, 230, 255'
        }
    ];

    const TAU = Math.PI * 2;
    const isCompact = window.matchMedia('(max-width: 760px)').matches;
    const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    const container = document.getElementById('canvas-container');
    const planetButtons = Array.from(document.querySelectorAll('[data-planet]'));
    const planetName = document.getElementById('planet-name');
    const planetKicker = document.getElementById('planet-kicker');
    const planetDescription = document.getElementById('planet-description');
    const transitionMeter = document.getElementById('transition-meter');
    const transitionMeterFill = document.getElementById('transition-meter-fill');
    const autoCycleInput = document.getElementById('auto-cycle');

    const renderer = new THREE.WebGLRenderer({
        antialias: true,
        alpha: false,
        powerPreference: 'high-performance'
    });

    // ATLAS: the field lives in a panel-bounded cell, not the whole viewport.
    // Sizing to window.innerWidth/innerHeight while the canvas is stretched to a
    // smaller container is what squashed the sphere into an oval whenever the
    // sidebar opened — the window never resizes, only this element does.
    function fieldSize() {
        const host = document.getElementById('canvas-container');
        const rect = host ? host.getBoundingClientRect() : null;
        if (rect && rect.width > 0 && rect.height > 0) {
            return { width: rect.width, height: rect.height };
        }
        return { width: window.innerWidth, height: window.innerHeight };
    }

    function responsivePixelRatio() {
        const cap = isCompact ? 1.45 : 1.85;
        return Math.min(window.devicePixelRatio || 1, cap);
    }

    function responsiveCameraZ() {
        const size = fieldSize();
        const aspect = size.width / size.height;
        if (aspect < 0.66) return 10.6;
        if (aspect < 0.95) return 9.55;
        return 8.55;
    }

    renderer.setPixelRatio(responsivePixelRatio());
    (function () { const s = fieldSize(); renderer.setSize(s.width, s.height); })();
    renderer.setClearColor(0x02030a, 1);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.08;
    container.appendChild(renderer.domElement);

    const scene = new THREE.Scene();
    scene.fog = new THREE.FogExp2(0x02030a, 0.015);

    const camera = new THREE.PerspectiveCamera(
        39,
        window.innerWidth / window.innerHeight,
        0.08,
        90
    );
    camera.position.set(0, 0.25, responsiveCameraZ());

    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.05;
    controls.enableRotate = true;
    controls.enablePan = true;
    controls.panSpeed = 1.0;
    controls.enableZoom = true;
    controls.zoomSpeed = 1.0;
    controls.minDistance = 2.0;
    controls.maxDistance = 30.0;
    controls.minPolarAngle = 0;
    controls.maxPolarAngle = Math.PI;
    controls.autoRotate = false;
    controls.target.set(0, 0.02, 0);
    controls.update();

    const guardedCameraOffset = new THREE.Vector3();
    const activeTouchPointers = new Set();
    let intendedOrbitRadius = THREE.MathUtils.clamp(
        camera.position.distanceTo(controls.target),
        controls.minDistance,
        controls.maxDistance
    );
    let manualZoomCaptureFrames = 0;
    let middleButtonDollyActive = false;

    function beginManualZoomCapture(frameCount = 12) {
        manualZoomCaptureFrames = Math.max(manualZoomCaptureFrames, frameCount);
    }

    renderer.domElement.addEventListener('wheel', () => {
        beginManualZoomCapture(14);
    }, { passive: true, capture: true });

    renderer.domElement.addEventListener('pointerdown', (event) => {
        if (event.pointerType === 'touch') {
            activeTouchPointers.add(event.pointerId);
            if (activeTouchPointers.size >= 2) beginManualZoomCapture(18);
        }
        if (event.button === 1) {
            middleButtonDollyActive = true;
            beginManualZoomCapture(18);
        }
    }, { passive: true, capture: true });

    renderer.domElement.addEventListener('pointermove', (event) => {
        if (event.pointerType === 'touch' && activeTouchPointers.size >= 2) {
            beginManualZoomCapture(18);
        }
        if (middleButtonDollyActive) beginManualZoomCapture(18);
    }, { passive: true, capture: true });

    function endZoomPointer(event) {
        if (event.pointerType === 'touch') {
            activeTouchPointers.delete(event.pointerId);
            if (activeTouchPointers.size > 0) beginManualZoomCapture(8);
        }
        if (event.button === 1) {
            middleButtonDollyActive = false;
            beginManualZoomCapture(8);
        }
    }

    renderer.domElement.addEventListener('pointerup', endZoomPointer, {
        passive: true,
        capture: true
    });
    renderer.domElement.addEventListener('pointercancel', endZoomPointer, {
        passive: true,
        capture: true
    });
    renderer.domElement.addEventListener('pointerleave', (event) => {
        if (event.pointerType === 'touch') activeTouchPointers.delete(event.pointerId);
        if (event.buttons === 0) middleButtonDollyActive = false;
    }, { passive: true, capture: true });

    renderer.domElement.addEventListener('gesturestart', () => {
        beginManualZoomCapture(18);
    }, { passive: true });
    renderer.domElement.addEventListener('gesturechange', () => {
        beginManualZoomCapture(18);
    }, { passive: true });

    function guardOrbitRadius() {
        guardedCameraOffset.copy(camera.position).sub(controls.target);
        let currentRadius = guardedCameraOffset.length();
        if (!Number.isFinite(currentRadius) || currentRadius < 1.0e-6) {
            guardedCameraOffset.set(0, 0.23, 1).normalize();
            currentRadius = 8.5;
        }
        intendedOrbitRadius = currentRadius;
    }

    const composer = new EffectComposer(renderer);
    composer.addPass(new RenderPass(scene, camera));

    const bloomPass = new UnrealBloomPass(
        new THREE.Vector2(window.innerWidth, window.innerHeight),
        0.50,
        0.30,
        0.50
    );
    composer.addPass(bloomPass);
    composer.addPass(new OutputPass());

    const noiseGLSL = `
        vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
        vec4 mod289(vec4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
        vec4 permute(vec4 x) { return mod289(((x * 34.0) + 1.0) * x); }
        vec4 taylorInvSqrt(vec4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

        float saturate(float value) {
            return clamp(value, 0.0, 1.0);
        }

        vec2 safeNormalize(vec2 value) {
            return value * inversesqrt(max(dot(value, value), 1.0e-12));
        }

        vec3 safeNormalize(vec3 value) {
            return value * inversesqrt(max(dot(value, value), 1.0e-12));
        }

        float safeAtan(float y, float x) {
            bool nearOrigin = abs(x) + abs(y) < 1.0e-7;
            return nearOrigin ? 0.0 : atan(y, x);
        }

        float sanitizeFloat(float value, float fallbackValue) {
            bool valid = value == value && abs(value) < 1.0e5;
            return valid ? value : fallbackValue;
        }

        vec3 sanitizeVec3(vec3 value, vec3 fallbackValue) {
            bool invalid = any(notEqual(value, value))
                || any(greaterThan(abs(value), vec3(1.0e5)));
            return invalid ? fallbackValue : value;
        }

        vec3 limitLuminance(vec3 color, float maximumLuminance) {
            vec3 safeColor = max(sanitizeVec3(color, vec3(0.0)), vec3(0.0));
            float luminance = dot(safeColor, vec3(0.2126, 0.7152, 0.0722));
            float scale = min(1.0, maximumLuminance / max(luminance, 1.0e-5));
            return safeColor * scale;
        }

        float snoise(vec3 v) {
            const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
            const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);

            vec3 i = floor(v + dot(v, C.yyy));
            vec3 x0 = v - i + dot(i, C.xxx);
            vec3 g = step(x0.yzx, x0.xyz);
            vec3 l = 1.0 - g;
            vec3 i1 = min(g.xyz, l.zxy);
            vec3 i2 = max(g.xyz, l.zxy);
            vec3 x1 = x0 - i1 + C.xxx;
            vec3 x2 = x0 - i2 + C.yyy;
            vec3 x3 = x0 - D.yyy;

            i = mod289(i);
            vec4 p = permute(
                permute(
                    permute(i.z + vec4(0.0, i1.z, i2.z, 1.0))
                    + i.y + vec4(0.0, i1.y, i2.y, 1.0)
                )
                + i.x + vec4(0.0, i1.x, i2.x, 1.0)
            );

            float n_ = 0.142857142857;
            vec3 ns = n_ * D.wyz - D.xzx;
            vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
            vec4 x_ = floor(j * ns.z);
            vec4 y_ = floor(j - 7.0 * x_);
            vec4 x = x_ * ns.x + ns.yyyy;
            vec4 y = y_ * ns.x + ns.yyyy;
            vec4 h = 1.0 - abs(x) - abs(y);
            vec4 b0 = vec4(x.xy, y.xy);
            vec4 b1 = vec4(x.zw, y.zw);
            vec4 s0 = floor(b0) * 2.0 + 1.0;
            vec4 s1 = floor(b1) * 2.0 + 1.0;
            vec4 sh = -step(h, vec4(0.0));
            vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
            vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
            vec3 p0 = vec3(a0.xy, h.x);
            vec3 p1 = vec3(a0.zw, h.y);
            vec3 p2 = vec3(a1.xy, h.z);
            vec3 p3 = vec3(a1.zw, h.w);
            vec4 norm = taylorInvSqrt(vec4(
                dot(p0, p0),
                dot(p1, p1),
                dot(p2, p2),
                dot(p3, p3)
            ));
            p0 *= norm.x;
            p1 *= norm.y;
            p2 *= norm.z;
            p3 *= norm.w;
            vec4 m = max(0.6 - vec4(
                dot(x0, x0),
                dot(x1, x1),
                dot(x2, x2),
                dot(x3, x3)
            ), 0.0);
            m *= m;
            return 42.0 * dot(
                m * m,
                vec4(
                    dot(p0, x0),
                    dot(p1, x1),
                    dot(p2, x2),
                    dot(p3, x3)
                )
            );
        }

        mat2 rotate2D(float angle) {
            float s = sin(angle);
            float c = cos(angle);
            return mat2(c, -s, s, c);
        }

        mat3 rotateX3(float angle) {
            float s = sin(angle);
            float c = cos(angle);
            return mat3(
                1.0, 0.0, 0.0,
                0.0, c, -s,
                0.0, s, c
            );
        }

        mat3 rotateZ3(float angle) {
            float s = sin(angle);
            float c = cos(angle);
            return mat3(
                c, -s, 0.0,
                s, c, 0.0,
                0.0, 0.0, 1.0
            );
        }
    `;

    const planetFunctionsGLSL = `
        const float PI = 3.141592653589793;
        const float TWO_PI = 6.283185307179586;

        float isPreset(float preset, float expected) {
            return 1.0 - step(0.5, abs(preset - expected));
        }

        vec3 aetheraPosition(vec3 seed, vec4 randomData, float time) {
            vec3 direction = safeNormalize(seed);
            float latitude = asin(clamp(direction.y, -1.0, 1.0));
            float continent = snoise(direction * 2.45 + vec3(0.0, time * 0.018, 0.0));
            float currentNoise = snoise(
                direction * 4.2
                + vec3(time * 0.045, -time * 0.018, time * 0.032)
            );
            float current = sin(
                latitude * 10.5
                + dot(direction, safeNormalize(vec3(0.74, 0.11, 0.66))) * 5.4
                + currentNoise * 1.35
                - time * 0.18
            );
            float radius = 2.08 + continent * 0.072 + current * 0.026;
            vec3 p = direction * radius;
            p.y *= 0.975;
            p.xz = rotate2D(sin(latitude * 3.0 + time * 0.08) * 0.018) * p.xz;
            return p;
        }

        vec3 pyraPosition(vec3 seed, vec4 randomData, float time) {
            vec3 direction = safeNormalize(seed);
            float terrain = snoise(direction * 3.4 + vec3(time * 0.012, 0.0, 0.0));
            float secondary = snoise(direction * 8.0 - vec3(0.0, time * 0.024, 0.0));
            float moltenLift = pow(max(secondary * 0.5 + 0.5, 0.0), 8.0);
            float radius = 2.08 + terrain * 0.125 + moltenLift * 0.090;
            return direction * radius;
        }

        vec3 orisonBodyPosition(vec3 seed, vec4 randomData, float time) {
            vec3 direction = safeNormalize(seed);
            float latitude = asin(clamp(direction.y, -1.0, 1.0));
            float bandNoise = snoise(
                direction * vec3(2.2, 5.8, 2.2)
                + vec3(time * 0.018, -time * 0.012, time * 0.014)
            );
            float band = sin(latitude * 18.0 + bandNoise * 1.8 + time * 0.06);
            float storm = snoise(
                direction * 4.15
                + vec3(-time * 0.021, time * 0.013, time * 0.026)
            );
            float radius = 2.07 + band * 0.020 + storm * 0.038;
            vec3 p = direction * radius;
            p.y *= 0.945;
            return p;
        }

        vec3 orisonRingPosition(vec3 seed, vec4 randomData, float time) {
            float radius = mix(2.18, 3.62, pow(randomData.x, 0.74));
            float angle = randomData.y * TWO_PI + time * (0.018 + randomData.w * 0.012);
            float lane = floor(randomData.z * 11.0) / 11.0;
            float gap = 0.92 + 0.08 * sin(lane * 71.0 + randomData.w * 16.0);
            radius *= gap;
            float vertical = (randomData.z - 0.5) * 0.115;
            vertical += snoise(vec3(cos(angle) * 2.1, sin(angle) * 2.1, radius * 1.7)) * 0.035;
            vec3 p = vec3(cos(angle) * radius, vertical, sin(angle) * radius);
            p = rotateZ3(0.34) * rotateX3(0.20) * p;
            return p;
        }

        vec3 vesperPosition(vec3 seed, vec4 randomData, float time) {
            vec3 direction = safeNormalize(seed);
            vec3 stepped = floor(direction * 7.0 + 0.5) / 7.0;
            vec3 facetedDirection = safeNormalize(mix(direction, stepped, 0.68));
            float cell = snoise(facetedDirection * 4.8);
            vec3 axisA = safeNormalize(vec3(0.82, 0.31, 0.48));
            vec3 axisB = safeNormalize(vec3(-0.24, 0.91, 0.34));
            vec3 axisC = safeNormalize(vec3(0.41, -0.17, 0.90));
            float lattice =
                sin(dot(facetedDirection, axisA) * 18.0)
                * sin(dot(facetedDirection, axisB) * 16.0)
                * sin(dot(facetedDirection, axisC) * 14.0);
            float seam = pow(abs(lattice), 5.5);
            float radius = 2.06 + cell * 0.145 + seam * 0.070;
            vec3 p = facetedDirection * radius;
            p.y *= 1.018;
            return p;
        }

        vec3 planetPosition(
            float preset,
            vec3 seed,
            vec4 randomData,
            float kind,
            float time
        ) {
            if (preset < 0.5) return aetheraPosition(seed, randomData, time);
            if (preset < 1.5) return pyraPosition(seed, randomData, time);
            if (preset < 2.5) {
                return kind > 0.5
                    ? orisonRingPosition(seed, randomData, time)
                    : orisonBodyPosition(seed, randomData, time);
            }
            return vesperPosition(seed, randomData, time);
        }

        vec3 aetheraColor(vec3 p, vec3 seed, vec4 randomData, float time) {
            vec3 direction = safeNormalize(seed);
            float latitude = asin(clamp(direction.y, -1.0, 1.0));
            float current = snoise(
                direction * 3.65
                + vec3(-time * 0.055, time * 0.025, time * 0.04)
            );
            float ribbonNoise = snoise(
                direction * 6.8
                + vec3(time * 0.025, -time * 0.06, time * 0.015)
            );
            float auroraWave = sin(
                latitude * 8.2
                + dot(direction, safeNormalize(vec3(0.71, -0.08, 0.70))) * 7.1
                + ribbonNoise * 1.8
                - time * 0.35
            );
            float aurora = pow(max(0.0, auroraWave), 5.0);
            float polar = smoothstep(0.48, 0.93, abs(direction.y));
            vec3 abyss = vec3(0.004, 0.028, 0.13);
            vec3 ocean = vec3(0.012, 0.34, 0.78);
            vec3 cyan = vec3(0.05, 0.95, 1.25);
            vec3 violet = vec3(0.58, 0.08, 1.05);
            vec3 color = mix(abyss, ocean, current * 0.5 + 0.5);
            color = mix(color, cyan, smoothstep(0.22, 0.80, current) * 0.55);
            color += mix(cyan, violet, polar) * aurora * (0.28 + polar * 0.62);
            color += vec3(0.08, 0.28, 0.52) * pow(max(0.0, snoise(direction * 9.0)), 5.0);
            return limitLuminance(color, 1.38);
        }

        vec3 pyraColor(vec3 p, vec3 seed, vec4 randomData, float time) {
            vec3 direction = safeNormalize(seed);
            float crust = snoise(direction * 3.2 + vec3(time * 0.018, 0.0, 0.0));
            float detail = abs(snoise(direction * 9.5 - vec3(0.0, time * 0.05, 0.0)));
            float crack = 1.0 - smoothstep(0.035, 0.18, detail);
            crack *= smoothstep(-0.32, 0.5, crust);
            float ember = pow(max(0.0, snoise(direction * 17.0 + time * 0.08)), 7.0);
            vec3 charcoal = mix(vec3(0.012, 0.006, 0.012), vec3(0.18, 0.028, 0.018), crust * 0.5 + 0.5);
            vec3 molten = mix(vec3(1.45, 0.035, 0.002), vec3(1.55, 0.72, 0.055), crack);
            vec3 color = charcoal;
            color += molten * crack * 1.58;
            color += vec3(1.35, 0.23, 0.025) * ember * 0.72;
            return limitLuminance(color, 1.70);
        }

        vec3 orisonColor(vec3 p, vec3 seed, vec4 randomData, float kind, float time) {
            if (kind > 0.5) {
                float ringRadius = length(p.xz);
                float lane = sin(ringRadius * 27.0 + randomData.w * 7.0);
                float dust = snoise(vec3(
                    cos(randomData.y * TWO_PI) * 2.2,
                    sin(randomData.y * TWO_PI) * 2.2,
                    ringRadius * 3.7
                ));
                vec3 antiqueGold = vec3(0.95, 0.52, 0.12);
                vec3 mineralTeal = vec3(0.05, 0.76, 0.66);
                vec3 duskViolet = vec3(0.33, 0.08, 0.55);
                vec3 color = mix(antiqueGold, mineralTeal, lane * 0.5 + 0.5);
                color = mix(color, duskViolet, smoothstep(0.50, 0.88, dust) * 0.42);
                return limitLuminance(color, 1.12);
            }

            vec3 direction = safeNormalize(seed);
            float latitude = asin(clamp(direction.y, -1.0, 1.0));
            float latitudeMask = abs(latitude) / (PI * 0.5);
            float broadFlow = snoise(
                direction * 2.45
                + vec3(time * 0.014, -time * 0.01, time * 0.018)
            );
            float fineFlow = snoise(
                direction * 7.2
                + vec3(-time * 0.032, time * 0.012, time * 0.024)
            );
            float band = sin(latitude * 18.0 + broadFlow * 2.4 + fineFlow * 0.55 + time * 0.045);
            float storm = snoise(
                direction * 4.3
                + vec3(time * 0.025, time * 0.012, -time * 0.018)
            );
            float stormCell = smoothstep(0.34, 0.88, storm)
                * (1.0 - smoothstep(0.72, 1.0, latitudeMask));

            vec3 midnight = vec3(0.012, 0.028, 0.085);
            vec3 bronze = vec3(0.58, 0.25, 0.055);
            vec3 pearl = vec3(0.82, 0.76, 0.50);
            vec3 deepTeal = vec3(0.012, 0.38, 0.46);
            vec3 jade = vec3(0.035, 0.86, 0.66);

            float brightBand = smoothstep(-0.30, 0.88, band);
            vec3 color = mix(midnight, bronze, broadFlow * 0.5 + 0.5);
            color = mix(color, pearl, brightBand * 0.48);
            color = mix(color, deepTeal, smoothstep(0.06, 0.74, fineFlow) * 0.62);
            color += jade * stormCell * 0.62;
            color *= mix(1.0, 0.78, smoothstep(0.65, 1.0, latitudeMask));
            return limitLuminance(color, 1.32);
        }

        vec3 vesperColor(vec3 p, vec3 seed, vec4 randomData, float time) {
            vec3 direction = safeNormalize(seed);
            float facet = floor((snoise(direction * 4.7) * 0.5 + 0.5) * 7.0) / 7.0;
            float polar = smoothstep(0.48, 0.96, abs(direction.y));
            float seamNoise = abs(snoise(direction * 10.0 + vec3(0.0, time * 0.025, 0.0)));
            float seam = 1.0 - smoothstep(0.025, 0.14, seamNoise);
            vec3 night = vec3(0.018, 0.006, 0.12);
            vec3 violet = vec3(0.45, 0.045, 0.92);
            vec3 amethyst = vec3(0.98, 0.18, 1.38);
            vec3 cyan = vec3(0.03, 1.08, 1.48);
            vec3 color = mix(night, violet, facet);
            color = mix(color, amethyst, smoothstep(0.60, 0.96, facet) * 0.72);
            color += cyan * seam * (0.38 + polar * 1.15);
            color += cyan * pow(polar, 5.0) * 0.50;
            return limitLuminance(color, 1.56);
        }

        vec3 planetColor(
            float preset,
            vec3 p,
            vec3 seed,
            vec4 randomData,
            float kind,
            float time
        ) {
            if (preset < 0.5) return aetheraColor(p, seed, randomData, time);
            if (preset < 1.5) return pyraColor(p, seed, randomData, time);
            if (preset < 2.5) return orisonColor(p, seed, randomData, kind, time);
            return vesperColor(p, seed, randomData, time);
        }
    `;

    const nebulaGeometry = new THREE.SphereGeometry(45, 48, 32);
    const nebulaMaterial = new THREE.ShaderMaterial({
        uniforms: {
            uTime: { value: 0 }
        },
        vertexShader: `
            varying vec3 vDirection;

            void main() {
                vDirection = normalize(position);
                gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
            }
        `,
        fragmentShader: `
            ${noiseGLSL}

            uniform float uTime;
            varying vec3 vDirection;

            void main() {
                vec3 direction = safeNormalize(vDirection);
                float broad = snoise(direction * 1.7 + vec3(0.0, uTime * 0.006, 0.0));
                float filaments = snoise(direction * 4.0 - vec3(uTime * 0.004, 0.0, 0.0));
                float cloud = smoothstep(0.12, 0.88, broad * 0.7 + filaments * 0.3);
                float horizon = pow(max(1.0 - abs(direction.y), 0.0), 4.0);
                vec3 midnight = vec3(0.0015, 0.002, 0.009);
                vec3 blue = vec3(0.018, 0.038, 0.10);
                vec3 violet = vec3(0.055, 0.018, 0.10);
                vec3 color = midnight;
                color += mix(blue, violet, filaments * 0.5 + 0.5) * cloud * horizon * 0.62;
                gl_FragColor = vec4(color, 1.0);
            }
        `,
        side: THREE.BackSide,
        depthWrite: false,
        fog: false
    });
    const nebula = new THREE.Mesh(nebulaGeometry, nebulaMaterial);
    scene.add(nebula);

    const starCount = isCompact ? 4800 : 8200;
    const starGeometry = new THREE.BufferGeometry();
    const starPositions = new Float32Array(starCount * 3);
    const starSizes = new Float32Array(starCount);
    const starSeeds = new Float32Array(starCount);

    for (let i = 0; i < starCount; i += 1) {
        const radius = THREE.MathUtils.lerp(12, 43, Math.pow(Math.random(), 0.62));
        const y = THREE.MathUtils.randFloatSpread(2);
        const theta = Math.random() * TAU;
        const radial = Math.sqrt(Math.max(0, 1 - y * y));

        starPositions[i * 3] = Math.cos(theta) * radial * radius;
        starPositions[i * 3 + 1] = y * radius;
        starPositions[i * 3 + 2] = Math.sin(theta) * radial * radius;
        starSizes[i] = 0.65 + Math.pow(Math.random(), 5) * 4.4;
        starSeeds[i] = Math.random();
    }

    starGeometry.setAttribute('position', new THREE.BufferAttribute(starPositions, 3));
    starGeometry.setAttribute('aSize', new THREE.BufferAttribute(starSizes, 1));
    starGeometry.setAttribute('aSeed', new THREE.BufferAttribute(starSeeds, 1));

    const starMaterial = new THREE.ShaderMaterial({
        uniforms: {
            uTime: { value: 0 },
            uPixelRatio: { value: renderer.getPixelRatio() },
            uTransitionEnergy: { value: 0 }
        },
        vertexShader: `
            uniform float uTime;
            uniform float uPixelRatio;
            uniform float uTransitionEnergy;
            attribute float aSize;
            attribute float aSeed;
            varying float vAlpha;
            varying vec3 vColor;

            void main() {
                vec3 p = position;
                float drift = uTime * (0.003 + aSeed * 0.004);
                float s = sin(drift);
                float c = cos(drift);
                p.xz = mat2(c, -s, s, c) * p.xz;

                vec4 mvPosition = modelViewMatrix * vec4(p, 1.0);
                gl_Position = projectionMatrix * mvPosition;
                gl_PointSize = aSize * uPixelRatio * (18.0 / max(1.0, -mvPosition.z));
                gl_PointSize *= 1.0 + uTransitionEnergy * (0.08 + aSeed * 0.10);

                float twinkle = 0.55 + 0.45 * sin(uTime * (0.8 + aSeed * 2.0) + aSeed * 31.0);
                vAlpha = (0.18 + aSeed * 0.58) * twinkle * (1.0 - uTransitionEnergy * 0.42);
                vColor = mix(vec3(0.48, 0.65, 1.0), vec3(1.0, 0.82, 0.64), aSeed * aSeed);
            }
        `,
        fragmentShader: `
            varying float vAlpha;
            varying vec3 vColor;

            void main() {
                vec2 uv = gl_PointCoord - 0.5;
                float distanceToCenter = length(uv);
                if (distanceToCenter > 0.5) discard;
                float core = exp(-distanceToCenter * 12.0);
                float glow = exp(-distanceToCenter * 4.5) * 0.3;
                gl_FragColor = vec4(vColor * (core + glow), vAlpha * (core + glow));
            }
        `,
        transparent: true,
        blending: THREE.AdditiveBlending,
        depthWrite: false,
        fog: false
    });
    const stars = new THREE.Points(starGeometry, starMaterial);
    scene.add(stars);

    const planetGroup = new THREE.Group();
    planetGroup.rotation.z = -0.055;
    scene.add(planetGroup);

    const surfaceGeometry = new THREE.IcosahedronGeometry(1, isCompact ? 5 : 6);

    const sharedPlanetUniforms = {
        uTime: { value: 0 },
        uFromPreset: { value: 0 },
        uToPreset: { value: 0 },
        uTransition: { value: 0 },
        uTransitionEnergy: { value: 0 }
    };

    const surfaceMaterial = new THREE.ShaderMaterial({
        uniforms: sharedPlanetUniforms,
        vertexShader: `
            ${noiseGLSL}
            ${planetFunctionsGLSL}

            uniform float uTime;
            uniform float uFromPreset;
            uniform float uToPreset;
            uniform float uTransition;
            uniform float uTransitionEnergy;

            varying vec3 vWorldPosition;
            varying vec3 vObjectPosition;
            varying vec3 vSeed;
            varying vec3 vNormalApprox;
            varying float vLocalMorph;
            varying float vScanFront;
            varying float vSweepCoordinate;

            float phaseCoordinate(vec3 seed, float time) {
                vec3 axisA = safeNormalize(vec3(0.82, 0.25, 0.52));
                vec3 axisB = safeNormalize(vec3(-0.18, 0.93, 0.32));
                float coordinate = dot(seed, axisA);
                coordinate += sin(dot(seed, axisB) * 6.2 - time * 0.72) * 0.055;
                coordinate += snoise(seed * 3.4 + vec3(0.0, time * 0.10, 0.0)) * 0.035;
                return coordinate;
            }

            void main() {
                vec3 seed = safeNormalize(position);
                vec4 randomData = vec4(
                    fract(sin(dot(seed.xy, vec2(12.9898, 78.233))) * 43758.5453),
                    fract(sin(dot(seed.yz, vec2(39.3468, 11.135))) * 24634.6345),
                    fract(sin(dot(seed.zx, vec2(73.156, 52.235))) * 56445.234),
                    fract(sin(dot(seed.xyz, vec3(19.19, 7.17, 41.73))) * 9531.317)
                );

                vec3 fromPosition = sanitizeVec3(
                    planetPosition(uFromPreset, seed, randomData, 0.0, uTime),
                    seed * 2.08
                );
                vec3 toPosition = sanitizeVec3(
                    planetPosition(uToPreset, seed, randomData, 0.0, uTime),
                    seed * 2.08
                );

                float coordinate = phaseCoordinate(seed, uTime);
                float scanPosition = mix(-1.24, 1.24, uTransition);
                float scanWidth = 0.115;
                float localMorph = 1.0 - smoothstep(
                    scanPosition - scanWidth,
                    scanPosition + scanWidth,
                    coordinate
                );
                float front = exp(-abs(coordinate - scanPosition) * 19.0);
                float coreFront = exp(-abs(coordinate - scanPosition) * 42.0);

                vec3 objectPosition = mix(fromPosition, toPosition, localMorph);
                vec3 normalDirection = safeNormalize(objectPosition);
                vec3 phaseAxis = safeNormalize(vec3(0.82, 0.25, 0.52));
                vec3 tangent = safeNormalize(cross(normalDirection, phaseAxis + vec3(0.001, 0.002, 0.003)));
                float ripple = sin(
                    dot(seed, safeNormalize(vec3(-0.31, 0.79, 0.53))) * 22.0
                    - uTime * 5.2
                );
                objectPosition += normalDirection * front * (0.052 + ripple * 0.022);
                objectPosition += tangent * coreFront * ripple * 0.028;
                objectPosition = sanitizeVec3(objectPosition, seed * 2.08);

                vec4 worldPosition = modelMatrix * vec4(objectPosition, 1.0);
                gl_Position = projectionMatrix * viewMatrix * worldPosition;

                vWorldPosition = worldPosition.xyz;
                vObjectPosition = objectPosition;
                vSeed = seed;
                vNormalApprox = safeNormalize(mat3(modelMatrix) * objectPosition);
                vLocalMorph = localMorph;
                vScanFront = front;
                vSweepCoordinate = coordinate;
            }
        `,
        fragmentShader: `
            ${noiseGLSL}
            ${planetFunctionsGLSL}

            uniform float uTime;
            uniform float uFromPreset;
            uniform float uToPreset;
            uniform float uTransition;
            uniform float uTransitionEnergy;

            varying vec3 vWorldPosition;
            varying vec3 vObjectPosition;
            varying vec3 vSeed;
            varying vec3 vNormalApprox;
            varying float vLocalMorph;
            varying float vScanFront;
            varying float vSweepCoordinate;

            void main() {
                vec4 randomData = vec4(
                    fract(sin(dot(vSeed.xy, vec2(12.9898, 78.233))) * 43758.5453),
                    fract(sin(dot(vSeed.yz, vec2(39.3468, 11.135))) * 24634.6345),
                    fract(sin(dot(vSeed.zx, vec2(73.156, 52.235))) * 56445.234),
                    fract(sin(dot(vSeed.xyz, vec3(19.19, 7.17, 41.73))) * 9531.317)
                );

                vec3 fromColor = planetColor(
                    uFromPreset, vObjectPosition, vSeed, randomData, 0.0, uTime
                );
                vec3 toColor = planetColor(
                    uToPreset, vObjectPosition, vSeed, randomData, 0.0, uTime
                );
                vec3 baseColor = mix(fromColor, toColor, vLocalMorph);

                vec3 normal = safeNormalize(vNormalApprox);
                vec3 viewDirection = safeNormalize(cameraPosition - vWorldPosition);
                vec3 keyDirection = safeNormalize(vec3(-0.70, 0.55, 0.85));
                vec3 rimDirection = safeNormalize(vec3(0.65, -0.25, -0.70));

                float ndl = dot(normal, keyDirection);
                float diffuse = saturate(ndl);
                float backLight = saturate(dot(normal, rimDirection));
                float facing = saturate(dot(normal, viewDirection));
                float fresnel = pow(max(1.0 - facing, 0.0), 3.0);
                float terminator = smoothstep(-0.34, 0.56, ndl);

                vec3 color = baseColor * (0.24 + diffuse * 1.04);
                color *= mix(0.46, 1.0, terminator);
                color += baseColor * backLight * 0.17;
                color += mix(vec3(0.10, 0.48, 1.05), baseColor, 0.46) * fresnel * 0.66;

                float micro = snoise(vSeed * 24.0 + vec3(0.0, uTime * 0.02, 0.0));
                color += baseColor * micro * 0.060;

                float thinCore = pow(clamp(vScanFront, 0.0, 1.0), 3.4);
                float paletteMix = smoothstep(-0.78, 0.78, vSweepCoordinate);
                vec3 phaseCyan = vec3(0.025, 0.92, 1.32);
                vec3 phaseViolet = vec3(1.02, 0.055, 1.18);
                vec3 phaseColor = mix(phaseCyan, phaseViolet, paletteMix);
                color = mix(color, phaseColor, vScanFront * 0.38);
                color += phaseColor * thinCore * 0.32;

                float separation = exp(-abs(vScanFront - 0.72) * 22.0) * 0.10;
                color *= 1.0 - separation;

                color = limitLuminance(color, 1.76);
                color = clamp(color, vec3(0.0), vec3(2.0));
                gl_FragColor = vec4(color, 1.0);
            }
        `,
        transparent: false,
        depthWrite: true,
        depthTest: true,
        side: THREE.FrontSide
    });

    const surfaceMesh = new THREE.Mesh(surfaceGeometry, surfaceMaterial);
    surfaceMesh.renderOrder = 2;
    surfaceMesh.visible = false;
    planetGroup.add(surfaceMesh);

    // --- ATLAS: 3D Geometric Audio-Reactive Core Visualizer ---
    const coreGeom = new THREE.IcosahedronGeometry(1.6, 2);
    const coreMaterial = new THREE.ShaderMaterial({
        uniforms: {
            uTime: { value: 0 },
            uVoiceEnergy: { value: 0 },
            uAudioRMS: { value: 0 },
            uAudioBass: { value: 0 },
            uAudioTreble: { value: 0 },
            uTransitionEnergy: { value: 0 },
            uAccentA: { value: new THREE.Color(0.2, 0.7, 1.0) },
            uAccentB: { value: new THREE.Color(0.9, 0.7, 0.3) }
        },
        vertexShader: `
            ${noiseGLSL}
            uniform float uTime;
            uniform float uVoiceEnergy;
            uniform float uAudioRMS;
            uniform float uAudioBass;
            uniform float uAudioTreble;
            uniform float uTransitionEnergy;

            varying vec3 vNormal;
            varying vec3 vWorldPos;
            varying float vDisplacement;
            varying vec3 vLocalPos;

            void main() {
                vLocalPos = position;
                vec3 norm = safeNormalize(position);
                
                float energy = max(uTransitionEnergy, uVoiceEnergy);
                float noisePulse = snoise(norm * 3.5 + vec3(0.0, uTime * 1.2, 0.0));
                float bassWave = sin(dot(norm, vec3(1.0, 2.0, 3.0)) * 4.0 - uTime * 5.0) * uAudioBass;
                float displacement = energy * 0.45 + uAudioRMS * 0.30 + bassWave * 0.15 + noisePulse * (0.08 + energy * 0.15);
                
                vec3 displacedPosition = position + norm * displacement;
                
                vNormal = safeNormalize(normalMatrix * norm);
                vDisplacement = displacement;
                vec4 worldPosition = modelMatrix * vec4(displacedPosition, 1.0);
                vWorldPos = worldPosition.xyz;
                
                gl_Position = projectionMatrix * viewMatrix * worldPosition;
            }
        `,
        fragmentShader: `
            uniform float uTime;
            uniform float uVoiceEnergy;
            uniform vec3 uAccentA;
            uniform vec3 uAccentB;

            varying vec3 vNormal;
            varying vec3 vWorldPos;
            varying float vDisplacement;
            varying vec3 vLocalPos;

            void main() {
                vec3 normal = safeNormalize(vNormal);
                vec3 viewDir = safeNormalize(cameraPosition - vWorldPos);
                
                float diffuse = max(0.2, dot(normal, safeNormalize(vec3(0.5, 1.0, 0.8))));
                float fresnel = pow(max(0.0, 1.0 - dot(normal, viewDir)), 2.5);
                
                vec3 color = mix(uAccentA, uAccentB, smoothstep(-1.5, 1.5, vLocalPos.y) + vDisplacement * 0.5);
                color = color * (0.4 + diffuse * 0.8) + vec3(0.1, 0.6, 1.0) * fresnel * (0.8 + uVoiceEnergy * 1.2);
                color += uAccentB * pow(max(0.0, vDisplacement), 1.8) * 2.0;

                gl_FragColor = vec4(limitLuminance(color, 2.0), 0.95);
            }
        `,
        transparent: true
    });

    const geometricCoreMesh = new THREE.Mesh(coreGeom, coreMaterial);
    geometricCoreMesh.renderOrder = 2;
    geometricCoreMesh.visible = false; // User design: solid core OFF
    planetGroup.add(geometricCoreMesh);

    const coreWireframeGeom = new THREE.WireframeGeometry(coreGeom);
    const coreWireframeMat = new THREE.LineBasicMaterial({
        color: 0xd4b059,
        transparent: true,
        opacity: 0.65,
        blending: THREE.AdditiveBlending
    });
    const coreWireframeMesh = new THREE.LineSegments(coreWireframeGeom, coreWireframeMat);
    geometricCoreMesh.add(coreWireframeMesh);

    // Center Red Energy Nucleus Lattice (User design: Red wireframe, scale 0.40)
    const nucleusGeom = new THREE.WireframeGeometry(new THREE.IcosahedronGeometry(0.40, 2));
    const nucleusMat = new THREE.LineBasicMaterial({
        color: 0xff0000,
        transparent: true,
        opacity: 0.90,
        blending: THREE.AdditiveBlending
    });
    const energyNucleusMesh = new THREE.LineSegments(nucleusGeom, nucleusMat);
    planetGroup.add(energyNucleusMesh);

    // Outer Ring 1: Cyan Wireframe Icosahedron (User design)
    const ring1Geom = new THREE.WireframeGeometry(new THREE.IcosahedronGeometry(2.3, 1));
    const ring1Mat = new THREE.LineBasicMaterial({ color: 0x00aaff, transparent: true, opacity: 0.85, blending: THREE.AdditiveBlending });
    const ringLattice1 = new THREE.LineSegments(ring1Geom, ring1Mat);
    planetGroup.add(ringLattice1);

    // Middle Ring 2: White Wireframe Octahedron (User design)
    const ring2Geom = new THREE.WireframeGeometry(new THREE.OctahedronGeometry(1.7, 1));
    const ring2Mat = new THREE.LineBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.80, blending: THREE.AdditiveBlending });
    const ringLattice2 = new THREE.LineSegments(ring2Geom, ring2Mat);
    planetGroup.add(ringLattice2);

    // Inner Ring 3: Yellow Wireframe Icosahedron (User design)
    const ring3Geom = new THREE.WireframeGeometry(new THREE.IcosahedronGeometry(1.1, 1));
    const ring3Mat = new THREE.LineBasicMaterial({ color: 0xffff00, transparent: true, opacity: 0.75, blending: THREE.AdditiveBlending });
    const ringLattice3 = new THREE.LineSegments(ring3Geom, ring3Mat);
    planetGroup.add(ringLattice3);

    const particleCount = isCompact ? 46000 : 78000;
    const particleGeometry = new THREE.BufferGeometry();
    const particleSeeds = new Float32Array(particleCount * 3);
    const particleRandom = new Float32Array(particleCount * 4);
    const particleKind = new Float32Array(particleCount);
    const particleLayer = new Float32Array(particleCount);

    for (let i = 0; i < particleCount; i += 1) {
        const y = THREE.MathUtils.randFloatSpread(2);
        const angle = Math.random() * TAU;
        const radial = Math.sqrt(Math.max(0, 1 - y * y));

        particleSeeds[i * 3] = Math.cos(angle) * radial;
        particleSeeds[i * 3 + 1] = y;
        particleSeeds[i * 3 + 2] = Math.sin(angle) * radial;

        particleRandom[i * 4] = Math.random();
        particleRandom[i * 4 + 1] = Math.random();
        particleRandom[i * 4 + 2] = Math.random();
        particleRandom[i * 4 + 3] = Math.random();

        particleLayer[i] = 0.075 + Math.pow(Math.random(), 1 / 3) * 0.925;
        particleKind[i] = Math.random() < 0.24 ? 1 : 0;
    }

    particleGeometry.setAttribute('position', new THREE.BufferAttribute(particleSeeds, 3));
    particleGeometry.setAttribute('aRandom', new THREE.BufferAttribute(particleRandom, 4));
    particleGeometry.setAttribute('aKind', new THREE.BufferAttribute(particleKind, 1));
    particleGeometry.setAttribute('aLayer', new THREE.BufferAttribute(particleLayer, 1));
    particleGeometry.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 8.0);

    const particleUniforms = {
        ...sharedPlanetUniforms,
        uPixelRatio: { value: renderer.getPixelRatio() },
        uPointScale: { value: isCompact ? 0.92 : 1.0 }
    };

    const volumetricVertexShader = `
        ${noiseGLSL}
        ${planetFunctionsGLSL}

        uniform float uTime;
        uniform float uFromPreset;
        uniform float uToPreset;
        uniform float uTransition;
        uniform float uTransitionEnergy;
        uniform float uPixelRatio;
        uniform float uPointScale;

        attribute vec4 aRandom;
        attribute float aKind;
        attribute float aLayer;

        varying vec3 vColor;
        varying float vAlpha;
        varying float vCore;
        varying float vEnergy;
        varying float vRibbon;

        float phaseCoordinate(vec3 seed, float time) {
            vec3 axisA = safeNormalize(vec3(0.82, 0.25, 0.52));
            vec3 axisB = safeNormalize(vec3(-0.18, 0.93, 0.32));
            float coordinate = dot(seed, axisA);
            coordinate += sin(dot(seed, axisB) * 6.2 - time * 0.72) * 0.055;
            coordinate += snoise(seed * 3.4 + vec3(0.0, time * 0.10, 0.0)) * 0.035;
            return coordinate;
        }

        void main() {
            vec3 seed = safeNormalize(position);
            vec3 fromSurface = sanitizeVec3(
                planetPosition(uFromPreset, seed, aRandom, aKind, uTime),
                seed * 2.08
            );
            vec3 toSurface = sanitizeVec3(
                planetPosition(uToPreset, seed, aRandom, aKind, uTime),
                seed * 2.08
            );

            float fromRing = isPreset(uFromPreset, 2.0) * step(0.5, aKind);
            float toRing = isPreset(uToPreset, 2.0) * step(0.5, aKind);
            vec3 fromMatter = mix(fromSurface * mix(0.54, 1.0, aLayer), fromSurface, fromRing);
            vec3 toMatter = mix(toSurface * mix(0.54, 1.0, aLayer), toSurface, toRing);

            float delayedTransition = clamp(uTransition + (aRandom.w - 0.5) * 0.10, 0.0, 1.0);
            float coordinate = phaseCoordinate(seed, uTime);
            float scanPosition = mix(-1.24, 1.24, delayedTransition);
            float localMorph = 1.0 - smoothstep(
                scanPosition - 0.13,
                scanPosition + 0.13,
                coordinate
            );
            float front = exp(-abs(coordinate - scanPosition) * 15.5);
            float coreFront = exp(-abs(coordinate - scanPosition) * 34.0);

            vec3 objectPosition = mix(fromMatter, toMatter, localMorph);
            vec3 normalDirection = safeNormalize(objectPosition);
            vec3 phaseAxis = safeNormalize(vec3(0.82, 0.25, 0.52));
            vec3 tangent = safeNormalize(cross(normalDirection, phaseAxis + vec3(0.001, 0.002, 0.003)));
            float handedness = mix(-1.0, 1.0, step(0.5, aRandom.z));
            float flutter = sin(
                dot(seed, safeNormalize(vec3(-0.31, 0.79, 0.53))) * (16.0 + aRandom.x * 12.0)
                - uTime * (4.0 + aRandom.y * 3.0)
            );
            objectPosition += normalDirection * front * (0.05 + aRandom.x * 0.24);
            objectPosition += tangent * handedness * front * flutter * (0.035 + aRandom.y * 0.16);
            objectPosition = sanitizeVec3(objectPosition, mix(fromMatter, toMatter, localMorph));

            vec4 mvPosition = modelViewMatrix * vec4(objectPosition, 1.0);
            gl_Position = projectionMatrix * mvPosition;

            float distanceScale = 30.0 / max(1.0, -mvPosition.z);
            gl_PointSize = (0.72 + aRandom.x * 1.65 + coreFront * 0.70)
                * distanceScale * uPixelRatio * uPointScale;

            vec3 fromColor = planetColor(
                uFromPreset, fromSurface, seed, aRandom, aKind, uTime
            );
            vec3 toColor = planetColor(
                uToPreset, toSurface, seed, aRandom, aKind, uTime
            );
            vec3 baseColor = mix(fromColor, toColor, localMorph);
            vec3 phaseCyan = vec3(0.025, 0.90, 1.30);
            vec3 phaseViolet = vec3(0.95, 0.055, 1.18);
            vec3 phaseAmber = vec3(1.24, 0.38, 0.025);
            vec3 phaseColor = aRandom.z < 0.60
                ? mix(phaseCyan, phaseViolet, aRandom.z / 0.60)
                : mix(phaseViolet, phaseAmber, (aRandom.z - 0.60) / 0.40);
            vec3 color = mix(baseColor, phaseColor, 0.62 + coreFront * 0.18);
            color = limitLuminance(color, 1.42);

            vColor = clamp(sanitizeVec3(color, vec3(0.0)), vec3(0.0), vec3(1.60));
            vAlpha = clamp(front * (0.026 + aRandom.w * 0.105), 0.0, 0.14);
            vCore = 0.12 + coreFront * 0.24;
            vEnergy = clamp(uTransitionEnergy, 0.0, 1.0);
            vRibbon = coreFront;
        }
    `;

    const particleMaterial = new THREE.ShaderMaterial({
        uniforms: particleUniforms,
        vertexShader: volumetricVertexShader,
        fragmentShader: `
            varying vec3 vColor;
            varying float vAlpha;
            varying float vCore;
            varying float vEnergy;
            varying float vRibbon;

            void main() {
                vec2 uv = gl_PointCoord - 0.5;
                float distanceToCenter = length(uv);
                if (distanceToCenter > 0.5) discard;

                float softGlow = exp(-distanceToCenter * mix(9.4, 7.2, vEnergy));
                float core = (1.0 - smoothstep(0.0, 0.25, distanceToCenter)) * vCore;
                float alpha = vAlpha * (softGlow * 0.76 + core * 0.30);
                vec3 color = vColor * (softGlow * (0.88 + vRibbon * 0.12) + core * 0.42);
                gl_FragColor = vec4(color, clamp(alpha, 0.0, 0.19));
            }
        `,
        transparent: true,
        blending: THREE.NormalBlending,
        depthWrite: false,
        depthTest: true
    });

    const planetParticles = new THREE.Points(particleGeometry, particleMaterial);
    planetParticles.renderOrder = 4;
    planetParticles.visible = false;
    planetGroup.add(planetParticles);

    const filamentCount = isCompact ? 4200 : 7600;
    const filamentGeometry = new THREE.BufferGeometry();
    const filamentSeeds = new Float32Array(filamentCount * 3);
    const filamentRandom = new Float32Array(filamentCount * 4);
    const filamentLayer = new Float32Array(filamentCount);
    const filamentKind = new Float32Array(filamentCount);

    for (let i = 0; i < filamentCount; i += 1) {
        const y = THREE.MathUtils.randFloatSpread(2);
        const angle = Math.random() * TAU;
        const radial = Math.sqrt(Math.max(0, 1 - y * y));
        filamentSeeds[i * 3] = Math.cos(angle) * radial;
        filamentSeeds[i * 3 + 1] = y;
        filamentSeeds[i * 3 + 2] = Math.sin(angle) * radial;
        filamentRandom[i * 4] = Math.random();
        filamentRandom[i * 4 + 1] = Math.random();
        filamentRandom[i * 4 + 2] = Math.random();
        filamentRandom[i * 4 + 3] = Math.random();
        filamentLayer[i] = 0.08 + Math.pow(Math.random(), 1 / 3) * 0.92;
        filamentKind[i] = Math.random() < 0.22 ? 1 : 0;
    }

    filamentGeometry.setAttribute('position', new THREE.BufferAttribute(filamentSeeds, 3));
    filamentGeometry.setAttribute('aRandom', new THREE.BufferAttribute(filamentRandom, 4));
    filamentGeometry.setAttribute('aLayer', new THREE.BufferAttribute(filamentLayer, 1));
    filamentGeometry.setAttribute('aKind', new THREE.BufferAttribute(filamentKind, 1));
    filamentGeometry.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 8.0);

    const filamentUniforms = {
        ...sharedPlanetUniforms,
        uPixelRatio: { value: renderer.getPixelRatio() }
    };

    const filamentMaterial = new THREE.ShaderMaterial({
        uniforms: filamentUniforms,
        vertexShader: `
            ${noiseGLSL}
            ${planetFunctionsGLSL}

            uniform float uTime;
            uniform float uFromPreset;
            uniform float uToPreset;
            uniform float uTransition;
            uniform float uTransitionEnergy;
            uniform float uPixelRatio;

            attribute vec4 aRandom;
            attribute float aLayer;
            attribute float aKind;
            varying vec3 vColor;
            varying float vAlpha;
            varying float vPulse;

            float phaseCoordinate(vec3 seed, float time) {
                vec3 axisA = safeNormalize(vec3(0.82, 0.25, 0.52));
                vec3 axisB = safeNormalize(vec3(-0.18, 0.93, 0.32));
                float coordinate = dot(seed, axisA);
                coordinate += sin(dot(seed, axisB) * 6.2 - time * 0.72) * 0.055;
                coordinate += snoise(seed * 3.4 + vec3(0.0, time * 0.10, 0.0)) * 0.035;
                return coordinate;
            }

            void main() {
                vec3 seed = safeNormalize(position);
                vec3 fromSurface = planetPosition(uFromPreset, seed, aRandom, aKind, uTime);
                vec3 toSurface = planetPosition(uToPreset, seed, aRandom, aKind, uTime);
                float fromRing = isPreset(uFromPreset, 2.0) * step(0.5, aKind);
                float toRing = isPreset(uToPreset, 2.0) * step(0.5, aKind);
                vec3 fromMatter = mix(fromSurface * mix(0.72, 1.0, aLayer), fromSurface, fromRing);
                vec3 toMatter = mix(toSurface * mix(0.72, 1.0, aLayer), toSurface, toRing);

                float delayedTransition = clamp(uTransition + (aRandom.w - 0.5) * 0.075, 0.0, 1.0);
                float coordinate = phaseCoordinate(seed, uTime);
                float scanPosition = mix(-1.24, 1.24, delayedTransition);
                float localMorph = 1.0 - smoothstep(scanPosition - 0.10, scanPosition + 0.10, coordinate);
                float front = exp(-abs(coordinate - scanPosition) * 28.0);

                vec3 p = mix(fromMatter, toMatter, localMorph);
                vec3 normalDirection = safeNormalize(p);
                vec3 phaseAxis = safeNormalize(vec3(0.82, 0.25, 0.52));
                vec3 tangent = safeNormalize(cross(normalDirection, phaseAxis + vec3(0.002, 0.001, 0.003)));
                float ray = step(0.73, aRandom.w);
                float pulse = front * ray;
                float wave = sin(aRandom.x * 22.0 + uTime * (5.0 + aRandom.y * 2.0));
                p += normalDirection * pulse * (0.10 + aRandom.x * 0.42);
                p += tangent * pulse * wave * (0.08 + aRandom.y * 0.24);

                vec4 mvPosition = modelViewMatrix * vec4(sanitizeVec3(p, mix(fromMatter, toMatter, localMorph)), 1.0);
                gl_Position = projectionMatrix * mvPosition;
                gl_PointSize = (0.62 + aRandom.x * 1.45 + pulse * 0.80)
                    * uPixelRatio * (29.0 / max(1.0, -mvPosition.z));

                vec3 cyan = vec3(0.035, 0.96, 1.40);
                vec3 magenta = vec3(1.02, 0.035, 1.24);
                vec3 amber = vec3(1.30, 0.40, 0.025);
                vColor = aRandom.z < 0.56
                    ? mix(cyan, magenta, aRandom.z / 0.56)
                    : mix(magenta, amber, (aRandom.z - 0.56) / 0.44);
                vAlpha = clamp(front * uTransitionEnergy * (0.012 + aRandom.w * 0.040), 0.0, 0.052);
                vPulse = pulse;
            }
        `,
        fragmentShader: `
            varying vec3 vColor;
            varying float vAlpha;
            varying float vPulse;
            void main() {
                vec2 uv = gl_PointCoord - 0.5;
                float d = length(uv);
                if (d > 0.5) discard;
                float core = exp(-d * 15.0);
                float glow = exp(-d * 8.2) * (0.12 + vPulse * 0.05);
                gl_FragColor = vec4(vColor * (core + glow), clamp(vAlpha * (core + glow), 0.0, 0.075));
            }
        `,
        transparent: true,
        blending: THREE.AdditiveBlending,
        depthWrite: false,
        depthTest: true
    });

    const transitionFilaments = new THREE.Points(filamentGeometry, filamentMaterial);
    transitionFilaments.renderOrder = 5;
    transitionFilaments.visible = false;
    planetGroup.add(transitionFilaments);

    const portalUniforms = {
        ...sharedPlanetUniforms,
        uTime: { value: 0 },
        uFromAccent: { value: new THREE.Color(0.10, 0.82, 1.0) },
        uToAccent: { value: new THREE.Color(0.72, 0.16, 1.0) }
    };

    const portalMaterial = new THREE.ShaderMaterial({
        uniforms: portalUniforms,
        vertexShader: `
            varying vec2 vUv;
            void main() {
                vUv = uv;
                gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
            }
        `,
        fragmentShader: `
            uniform float uTime;
            uniform float uTransition;
            uniform float uTransitionEnergy;
            uniform vec3 uFromAccent;
            uniform vec3 uToAccent;
            varying vec2 vUv;

            float ringLine(float radius, float target, float width) {
                return exp(-abs(radius - target) / max(width, 0.0001));
            }

            void main() {
                vec2 p = (vUv - 0.5) * 2.0;
                float radius = length(p);
                float angle = atan(p.y, p.x);
                float burst = exp(-pow((uTransition - 0.52) / 0.105, 2.0));
                float progress = smoothstep(0.37, 0.72, uTransition);
                float ringRadius = mix(0.18, 1.30, progress);
                float warpedRadius = ringRadius
                    + sin(angle * 8.0 - uTime * 4.0) * 0.022
                    + sin(angle * 3.0 + uTime * 2.4) * 0.014;
                float shock = ringLine(radius, warpedRadius, 0.017) * burst;
                float echo = ringLine(radius, warpedRadius * 0.72, 0.013) * burst * 0.42;
                float lens = exp(-radius * radius * 7.5) * burst;

                vec3 color = mix(uFromAccent, uToAccent, smoothstep(0.28, 0.74, uTransition));
                vec3 secondary = mix(vec3(0.03, 0.78, 1.0), vec3(0.82, 0.08, 0.96), smoothstep(0.30, 0.70, uTransition));
                vec3 finalColor = color * shock * 0.58;
                finalColor += secondary * echo * 0.34;
                finalColor += mix(color, secondary, 0.5) * lens * 0.055;

                float alpha = shock * 0.105 + echo * 0.055 + lens * 0.020;
                alpha *= 1.0 - smoothstep(1.40, 1.62, radius);
                if (alpha < 0.0015) discard;
                gl_FragColor = vec4(finalColor, clamp(alpha, 0.0, 0.12));
            }
        `,
        transparent: true,
        blending: THREE.AdditiveBlending,
        depthWrite: false,
        depthTest: false,
        side: THREE.DoubleSide
    });

    const portalPlane = new THREE.Mesh(
        new THREE.PlaneGeometry(5.6, 5.6, 1, 1),
        portalMaterial
    );
    portalPlane.renderOrder = 8;
    portalPlane.visible = false;
    scene.add(portalPlane);

    const atmosphereGeometry = new THREE.IcosahedronGeometry(1, isCompact ? 4 : 5);
    const atmosphereMaterial = new THREE.ShaderMaterial({
        uniforms: sharedPlanetUniforms,
        vertexShader: `
            ${noiseGLSL}
            ${planetFunctionsGLSL}

            uniform float uTime;
            uniform float uFromPreset;
            uniform float uToPreset;
            uniform float uTransition;
            uniform float uTransitionEnergy;

            varying vec3 vWorldPosition;
            varying vec3 vNormalApprox;
            varying float vLocalMorph;
            varying float vFront;

            float phaseCoordinate(vec3 seed, float time) {
                vec3 axisA = safeNormalize(vec3(0.82, 0.25, 0.52));
                vec3 axisB = safeNormalize(vec3(-0.18, 0.93, 0.32));
                float coordinate = dot(seed, axisA);
                coordinate += sin(dot(seed, axisB) * 6.2 - time * 0.72) * 0.055;
                coordinate += snoise(seed * 3.4 + vec3(0.0, time * 0.10, 0.0)) * 0.035;
                return coordinate;
            }

            void main() {
                vec3 seed = safeNormalize(position);
                vec4 randomData = vec4(0.17, 0.42, 0.73, 0.91);
                vec3 fromPosition = sanitizeVec3(
                    planetPosition(uFromPreset, seed, randomData, 0.0, uTime),
                    seed * 2.08
                );
                vec3 toPosition = sanitizeVec3(
                    planetPosition(uToPreset, seed, randomData, 0.0, uTime),
                    seed * 2.08
                );
                float coordinate = phaseCoordinate(seed, uTime);
                float scanPosition = mix(-1.24, 1.24, uTransition);
                float localMorph = 1.0 - smoothstep(scanPosition - 0.14, scanPosition + 0.14, coordinate);
                float front = exp(-abs(coordinate - scanPosition) * 17.0);
                vec3 objectPosition = mix(fromPosition, toPosition, localMorph) * 1.065;
                objectPosition = sanitizeVec3(objectPosition, seed * 2.20);

                vec4 worldPosition = modelMatrix * vec4(objectPosition, 1.0);
                gl_Position = projectionMatrix * viewMatrix * worldPosition;
                vWorldPosition = worldPosition.xyz;
                vNormalApprox = safeNormalize(mat3(modelMatrix) * objectPosition);
                vLocalMorph = localMorph;
                vFront = front;
            }
        `,
        fragmentShader: `
            ${noiseGLSL}

            uniform float uFromPreset;
            uniform float uToPreset;
            uniform float uTransitionEnergy;

            varying vec3 vWorldPosition;
            varying vec3 vNormalApprox;
            varying float vLocalMorph;
            varying float vFront;

            vec3 atmosphereColor(float preset) {
                if (preset < 0.5) return vec3(0.055, 0.42, 0.72);
                if (preset < 1.5) return vec3(0.72, 0.10, 0.018);
                if (preset < 2.5) return vec3(0.035, 0.40, 0.36);
                return vec3(0.30, 0.08, 0.68);
            }

            void main() {
                vec3 normal = safeNormalize(vNormalApprox);
                vec3 viewDirection = safeNormalize(cameraPosition - vWorldPosition);
                float facing = saturate(dot(normal, viewDirection));
                float fresnel = pow(max(1.0 - facing, 0.0), 2.4);
                vec3 color = mix(
                    atmosphereColor(uFromPreset),
                    atmosphereColor(uToPreset),
                    vLocalMorph
                );
                vec3 phaseTint = mix(vec3(0.03, 0.66, 1.02), vec3(0.72, 0.06, 0.94), vLocalMorph);
                color = mix(color, phaseTint, vFront * 0.28);
                float alpha = fresnel * (0.23 + vFront * 0.040);
                color = limitLuminance(color, 1.02);
                alpha = clamp(sanitizeFloat(alpha, 0.0), 0.0, 0.34);
                gl_FragColor = vec4(color * fresnel * 0.92, alpha);
            }
        `,
        transparent: true,
        blending: THREE.AdditiveBlending,
        side: THREE.BackSide,
        depthWrite: false
    });

    const atmosphereMesh = new THREE.Mesh(atmosphereGeometry, atmosphereMaterial);
    atmosphereMesh.renderOrder = 3;
    atmosphereMesh.visible = false;
    planetGroup.add(atmosphereMesh);

    const ringGeometry = new THREE.RingGeometry(2.16, 3.68, 320, 12);
    const ringMaterial = new THREE.ShaderMaterial({
        uniforms: {
            ...sharedPlanetUniforms,
            uOpacity: { value: 0 }
        },
        vertexShader: `
            ${noiseGLSL}

            uniform float uTime;
            uniform float uTransitionEnergy;
            varying vec2 vLocal;
            varying float vNoise;

            void main() {
                vec3 p = position;
                float radius = length(p.xy);
                float angle = safeAtan(p.y, p.x);
                float warp = snoise(vec3(cos(angle), sin(angle), radius * 1.7 + uTime * 0.035));
                p.z += warp * 0.032;
                p.xy = rotate2D(uTime * 0.004) * p.xy;

                vLocal = p.xy;
                vNoise = warp;
                gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);
            }
        `,
        fragmentShader: `
            ${noiseGLSL}

            uniform float uTime;
            uniform float uOpacity;
            uniform float uTransitionEnergy;
            varying vec2 vLocal;
            varying float vNoise;

            void main() {
                float radius = length(vLocal);
                vec2 ringDirection = safeNormalize(vLocal + vec2(0.00001));
                float lane = sin(radius * 47.0 + sin(radius * 8.0) * 2.0);
                float fineLane = sin(radius * 126.0 + (ringDirection.x * ringDirection.y) * 7.5);
                float breakNoise = snoise(vec3(
                    ringDirection * 2.35,
                    radius * 4.8 + uTime * 0.03
                ));
                float gaps = smoothstep(-0.50, 0.16, breakNoise + lane * 0.28);
                float edge = smoothstep(2.16, 2.31, radius) * (1.0 - smoothstep(3.48, 3.68, radius));

                vec3 gold = vec3(0.92, 0.49, 0.10);
                vec3 ice = vec3(0.035, 0.73, 0.65);
                vec3 violet = vec3(0.34, 0.055, 0.55);
                vec3 color = mix(gold, ice, lane * 0.5 + 0.5);
                color = mix(color, violet, smoothstep(0.72, 0.98, fineLane) * 0.40);
                color += vec3(0.34, 0.31, 0.19) * abs(fineLane) * 0.08;

                float alpha = edge * gaps * (0.115 + abs(lane) * 0.145 + abs(fineLane) * 0.060);
                alpha *= uOpacity;
                color = limitLuminance(color, 1.05);
                alpha = clamp(sanitizeFloat(alpha, 0.0), 0.0, 0.40);
                gl_FragColor = vec4(color, alpha);
            }
        `,
        transparent: true,
        blending: THREE.NormalBlending,
        depthWrite: false,
        side: THREE.DoubleSide
    });

    const ringMesh = new THREE.Mesh(ringGeometry, ringMaterial);
    ringMesh.rotation.set(Math.PI * 0.5 + 0.20, 0.0, 0.34);
    ringMesh.renderOrder = 1;
    planetGroup.add(ringMesh);

    const arcCount = isCompact ? 1200 : 2200;
    const arcGeometry = new THREE.BufferGeometry();
    const arcPositions = new Float32Array(arcCount * 3);
    const arcRandom = new Float32Array(arcCount * 2);

    for (let i = 0; i < arcCount; i += 1) {
        const angle = Math.random() * TAU;
        const radius = THREE.MathUtils.lerp(3.9, 5.8, Math.pow(Math.random(), 0.72));
        arcPositions[i * 3] = Math.cos(angle) * radius;
        arcPositions[i * 3 + 1] = THREE.MathUtils.randFloatSpread(0.45);
        arcPositions[i * 3 + 2] = Math.sin(angle) * radius;
        arcRandom[i * 2] = Math.random();
        arcRandom[i * 2 + 1] = Math.random();
    }

    arcGeometry.setAttribute('position', new THREE.BufferAttribute(arcPositions, 3));
    arcGeometry.setAttribute('aRandom', new THREE.BufferAttribute(arcRandom, 2));

    const arcMaterial = new THREE.ShaderMaterial({
        uniforms: {
            uTime: { value: 0 },
            uPixelRatio: { value: renderer.getPixelRatio() },
            uTransitionEnergy: { value: 0 }
        },
        vertexShader: `
            uniform float uTime;
            uniform float uPixelRatio;
            uniform float uTransitionEnergy;
            attribute vec2 aRandom;
            varying float vAlpha;
            varying vec3 vColor;

            void main() {
                vec3 p = position;
                float angle = uTime * (0.035 + aRandom.x * 0.055);
                float s = sin(angle);
                float c = cos(angle);
                p.xz = mat2(c, -s, s, c) * p.xz;
                p.y += sin(uTime * 0.45 + aRandom.y * 13.0 + length(p.xz)) * 0.13;
                p *= 1.0 + uTransitionEnergy * 0.035;

                vec4 mvPosition = modelViewMatrix * vec4(p, 1.0);
                gl_Position = projectionMatrix * mvPosition;
                gl_PointSize = (0.7 + aRandom.x * 1.5) * uPixelRatio * (25.0 / max(1.0, -mvPosition.z));
                vAlpha = (0.05 + aRandom.y * 0.16) * (1.0 - uTransitionEnergy * 0.52);
                vColor = mix(vec3(0.24, 0.48, 1.0), vec3(0.85, 0.35, 1.0), aRandom.x);
            }
        `,
        fragmentShader: `
            varying float vAlpha;
            varying vec3 vColor;

            void main() {
                vec2 uv = gl_PointCoord - 0.5;
                float d = length(uv);
                if (d > 0.5) discard;
                float glow = exp(-d * 7.0);
                gl_FragColor = vec4(vColor * glow, vAlpha * glow);
            }
        `,
        transparent: true,
        blending: THREE.AdditiveBlending,
        depthWrite: false
    });

    const orbitalArcs = new THREE.Points(arcGeometry, arcMaterial);
    orbitalArcs.rotation.set(0.18, 0.0, -0.28);
    planetGroup.add(orbitalArcs);

    const transitionState = {
        active: false,
        from: 0,
        to: 0,
        queued: null,
        startTime: 0,
        duration: prefersReducedMotion ? 0.82 : 1.28,
        raw: 0,
        eased: 0,
        energy: 0,
        current: 0,
        settledAt: 0
    };

    function smootherStep(value) {
        const x = THREE.MathUtils.clamp(value, 0, 1);
        return x * x * x * (x * (x * 6 - 15) + 10);
    }

    function cinematicEase(value) {
        const x = THREE.MathUtils.clamp(value, 0, 1);
        if (x < 0.5) return 0.5 * Math.pow(x * 2, 1.22);
        return 1 - 0.5 * Math.pow((1 - x) * 2, 1.22);
    }

    function transitionEnergy(easedProgress) {
        const progress = THREE.MathUtils.clamp(easedProgress, 0, 1);
        const pulse = Math.max(0, Math.sin(Math.PI * progress));
        const energy = Math.pow(pulse, 1.35);
        return Number.isFinite(energy) ? energy : 0;
    }

    function setSharedUniform(name, value) {
        sharedPlanetUniforms[name].value = value;
        particleUniforms[name].value = value;
        ringMaterial.uniforms[name].value = value;
    }

    function accentStringToColor(value) {
        const channels = value.split(',').map((part) => Number(part.trim()) / 255);
        return new THREE.Color(
            Number.isFinite(channels[0]) ? channels[0] : 0.2,
            Number.isFinite(channels[1]) ? channels[1] : 0.7,
            Number.isFinite(channels[2]) ? channels[2] : 1.0
        );
    }

    function updatePortalPalette(fromIndex, toIndex) {
        portalUniforms.uFromAccent.value.copy(accentStringToColor(PLANETS[fromIndex].accentA));
        portalUniforms.uToAccent.value.copy(accentStringToColor(PLANETS[toIndex].accentB));
    }

    function setDocumentAccent(index) {
        const planet = PLANETS[index];
        document.documentElement.style.setProperty('--accent-a', planet.accentA);
        document.documentElement.style.setProperty('--accent-b', planet.accentB);
    }

    function updatePlanetCopy(index, isTransmuting = false) {
        const planet = PLANETS[index];
        planetKicker.textContent = isTransmuting
            ? `Phasing into ${planet.kicker.toLowerCase()}`
            : planet.kicker;
        planetName.textContent = planet.name;
        planetDescription.textContent = planet.description;
    }

    function updateButtonState(currentIndex, targetIndex = null) {
        planetButtons.forEach((button) => {
            const index = Number(button.dataset.planet);
            const isCurrent = index === currentIndex && targetIndex === null;
            const isTarget = targetIndex !== null && index === targetIndex;
            button.classList.toggle('is-active', isCurrent);
            button.classList.toggle('is-target', isTarget);
            button.setAttribute('aria-pressed', String(isCurrent || isTarget));
        });
    }

    function beginTransition(targetIndex, nowSeconds) {
        const normalizedTarget = (targetIndex + PLANETS.length) % PLANETS.length;

        if (transitionState.active) {
            transitionState.queued = normalizedTarget;
            return;
        }

        if (normalizedTarget === transitionState.current) return;

        transitionState.active = true;
        transitionState.from = transitionState.current;
        transitionState.to = normalizedTarget;
        transitionState.startTime = nowSeconds;
        transitionState.raw = 0;
        transitionState.eased = 0;
        transitionState.energy = 0;
        updatePortalPalette(transitionState.from, transitionState.to);

        setSharedUniform('uFromPreset', transitionState.from);
        setSharedUniform('uToPreset', transitionState.to);
        setSharedUniform('uTransition', 0);
        setSharedUniform('uTransitionEnergy', 0);

        updatePlanetCopy(normalizedTarget, true);
        updateButtonState(transitionState.current, normalizedTarget);
        setDocumentAccent(normalizedTarget);
        transitionMeter.classList.add('is-active');
        transitionMeterFill.style.width = '0%';
    }

    function settleTransition(nowSeconds) {
        transitionState.current = transitionState.to;
        transitionState.active = false;
        transitionState.raw = 1;
        transitionState.eased = 1;
        transitionState.energy = 0;
        transitionState.settledAt = nowSeconds;

        setSharedUniform('uFromPreset', transitionState.current);
        setSharedUniform('uToPreset', transitionState.current);
        setSharedUniform('uTransition', 0);
        setSharedUniform('uTransitionEnergy', 0);

        updatePlanetCopy(transitionState.current, false);
        updateButtonState(transitionState.current, null);
        setDocumentAccent(transitionState.current);
        transitionMeter.classList.remove('is-active');
        transitionMeterFill.style.width = '100%';

        if (transitionState.queued !== null) {
            const queued = transitionState.queued;
            transitionState.queued = null;
            if (queued !== transitionState.current) {
                beginTransition(queued, nowSeconds + 0.001);
            }
        }
    }

    function updateTransition(nowSeconds) {
        if (!transitionState.active) return;

        const raw = THREE.MathUtils.clamp(
            (nowSeconds - transitionState.startTime) / transitionState.duration,
            0,
            1
        );
        const eased = cinematicEase(raw);
        const energy = transitionEnergy(eased);

        transitionState.raw = raw;
        transitionState.eased = eased;
        transitionState.energy = energy;

        setSharedUniform('uTransition', eased);
        setSharedUniform('uTransitionEnergy', energy);
        transitionMeterFill.style.width = `${(raw * 100).toFixed(2)}%`;

        if (raw >= 1) {
            settleTransition(nowSeconds);
        }
    }

    let latestTime = 0;

    planetButtons.forEach((button) => {
        button.addEventListener('click', () => {
            beginTransition(Number(button.dataset.planet), latestTime);
        });
    });

    window.addEventListener('keydown', (event) => {
        const activeElement = document.activeElement;
        const tagName = activeElement?.tagName?.toLowerCase();
        if (tagName === 'input' || tagName === 'textarea') return;

        if (event.key === 'ArrowRight' || event.key === 'ArrowDown') {
            event.preventDefault();
            const base = transitionState.active ? transitionState.to : transitionState.current;
            beginTransition(base + 1, latestTime);
        } else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') {
            event.preventDefault();
            const base = transitionState.active ? transitionState.to : transitionState.current;
            beginTransition(base - 1, latestTime);
        } else if (event.key === ' ') {
            event.preventDefault();
            const base = transitionState.active ? transitionState.to : transitionState.current;
            beginTransition(base + 1, latestTime);
        }
    });

    function handleResize() {
        const size = fieldSize();
        const width = size.width;
        const height = size.height;
        const pixelRatio = responsivePixelRatio();

        camera.aspect = width / height;
        camera.updateProjectionMatrix();

        renderer.setPixelRatio(pixelRatio);
        renderer.setSize(width, height);
        composer.setPixelRatio(pixelRatio);
        composer.setSize(width, height);

        camera.position.setLength(responsiveCameraZ());

        particleUniforms.uPixelRatio.value = pixelRatio;
        filamentUniforms.uPixelRatio.value = pixelRatio;
        starMaterial.uniforms.uPixelRatio.value = pixelRatio;
        arcMaterial.uniforms.uPixelRatio.value = pixelRatio;
    }

    window.addEventListener('resize', handleResize, { passive: true });

    // ATLAS: the sidebar changes this element's size without a window resize,
    // so the element itself has to be watched or the aspect ratio goes stale.
    (function () {
        const host = document.getElementById('canvas-container');
        if (host && typeof ResizeObserver !== 'undefined') {
            new ResizeObserver(handleResize).observe(host);
        }
    })();

    const clock = new THREE.Clock();
    transitionState.settledAt = 0;
    const AUTO_HOLD_SECONDS = prefersReducedMotion ? 6.0 : 4.2;

    let smoothedVoiceEnergy = 0;
    let smoothedAudioRMS = 0;
    let smoothedAudioBass = 0;
    let smoothedAudioTreble = 0;

    function animate() {
        requestAnimationFrame(animate);

        const delta = Math.min(clock.getDelta(), 0.04);
        const time = clock.elapsedTime;
        latestTime = time;
        updateTransition(time);

        // ATLAS: Audio & Sovereign state telemetry processing
        const rawVoice = window.__atlasVoiceEnergy || 0;
        const rawAudio = window.__atlasAudioEnergy || {};
        smoothedVoiceEnergy += (rawVoice - smoothedVoiceEnergy) * 0.18;
        smoothedAudioRMS += (((rawAudio.rms !== undefined ? rawAudio.rms : rawVoice)) - smoothedAudioRMS) * 0.18;
        smoothedAudioBass += (((rawAudio.bass !== undefined ? rawAudio.bass : rawVoice)) - smoothedAudioBass) * 0.18;
        smoothedAudioTreble += (((rawAudio.treble !== undefined ? rawAudio.treble : rawVoice)) - smoothedAudioTreble) * 0.18;

        const sovereignState = window.__atlasSovereignState || 'idle';
        let speedMultiplier = 1.0;
        if (sovereignState === 'speaking') speedMultiplier = 2.2;
        else if (sovereignState === 'processing') speedMultiplier = 3.5;
        else if (sovereignState === 'listening') speedMultiplier = 1.4;

        const energy = Math.max(transitionState.energy, smoothedVoiceEnergy);
        surfaceMaterial.depthWrite = false;
        planetParticles.visible = transitionState.active;
        transitionFilaments.visible = transitionState.active;

        // Core uniforms update
        coreMaterial.uniforms.uTime.value = time;
        coreMaterial.uniforms.uVoiceEnergy.value = smoothedVoiceEnergy;
        coreMaterial.uniforms.uAudioRMS.value = smoothedAudioRMS;
        coreMaterial.uniforms.uAudioBass.value = smoothedAudioBass;
        coreMaterial.uniforms.uAudioTreble.value = smoothedAudioTreble;
        coreMaterial.uniforms.uTransitionEnergy.value = transitionState.energy;

        const currentPlanet = PLANETS[transitionState.current] || PLANETS[0];
        coreMaterial.uniforms.uAccentA.value.copy(accentStringToColor(currentPlanet.accentA));
        coreMaterial.uniforms.uAccentB.value.copy(accentStringToColor(currentPlanet.accentB));

        // Nucleus update (Red wireframe center lattice, pulsing with speech audio)
        energyNucleusMesh.scale.setScalar(1.0 + smoothedVoiceEnergy * 0.90 + smoothedAudioBass * 0.40);
        energyNucleusMesh.rotation.x += delta * 0.8 * speedMultiplier;
        energyNucleusMesh.rotation.y += delta * 1.2 * speedMultiplier;

        // Nested Platonic Wireframe Rings Counter-Rotations & Speech Expansion
        const exp = 1.0 + smoothedVoiceEnergy * 0.12;

        // Ring 1 (Cyan Icosahedron Outer Lattice)
        ringLattice1.rotation.x += delta * 0.25 * speedMultiplier;
        ringLattice1.rotation.y += delta * 0.35 * speedMultiplier;
        ringLattice1.scale.setScalar(exp);

        // Ring 2 (White Octahedron Middle Lattice)
        ringLattice2.rotation.y -= delta * 0.30 * speedMultiplier;
        ringLattice2.rotation.z += delta * 0.20 * speedMultiplier;
        ringLattice2.scale.setScalar(exp);

        // Ring 3 (Yellow Icosahedron Inner Lattice)
        ringLattice3.rotation.x += delta * 0.20 * speedMultiplier;
        ringLattice3.rotation.z -= delta * 0.15 * speedMultiplier;
        ringLattice3.scale.setScalar(exp);

        sharedPlanetUniforms.uTime.value = time;
        particleUniforms.uTime.value = time;
        nebulaMaterial.uniforms.uTime.value = time;
        starMaterial.uniforms.uTime.value = time;
        starMaterial.uniforms.uTransitionEnergy.value = energy;
        arcMaterial.uniforms.uTime.value = time;
        arcMaterial.uniforms.uTransitionEnergy.value = energy;
        portalUniforms.uTime.value = time;
        portalPlane.visible = transitionState.active;
        if (portalPlane.visible) {
            portalPlane.quaternion.copy(camera.quaternion);
            portalPlane.scale.setScalar(1.0);
        }

        const fromHasRing = transitionState.active
            ? Number(transitionState.from === 2)
            : Number(transitionState.current === 2);
        const toHasRing = transitionState.active
            ? Number(transitionState.to === 2)
            : fromHasRing;
        const ringMorph = transitionState.active
            ? smootherStep(transitionState.eased)
            : 0;
        ringMaterial.uniforms.uOpacity.value = THREE.MathUtils.lerp(
            fromHasRing,
            toHasRing,
            ringMorph
        );

        planetGroup.rotation.y += (idleRotation + energy * 0.12) * delta;
        planetGroup.rotation.x = Math.sin(time * 0.12) * 0.025;
        planetGroup.scale.set(1.0, 1.0, 1.0);

        orbitalArcs.rotation.y = time * 0.018;
        orbitalArcs.rotation.z = -0.28 + Math.sin(time * 0.09) * 0.055;
        stars.rotation.y = time * 0.0016;
        nebula.rotation.y = -time * 0.00045;

        bloomPass.strength = 0.20 + energy * 0.15;
        bloomPass.radius = 0.25 + energy * 0.05;
        bloomPass.threshold = 0.65;
        renderer.toneMappingExposure = 1.08;

        if (
            autoCycleInput.checked
            && !transitionState.active
            && time - transitionState.settledAt > AUTO_HOLD_SECONDS
        ) {
            beginTransition(transitionState.current + 1, time);
        }

        controls.update();
        guardOrbitRadius();
        composer.render();
    }

    const idleRotation = 0.035;
    updatePortalPalette(0, 0);
    setDocumentAccent(0);
    updatePlanetCopy(0, false);
    updateButtonState(0, null);
    handleResize();
    animate();
