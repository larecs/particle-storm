"""3D simplex noise with analytic derivatives for CPU and GPU kernels.

Port of Stefan Gustavson and Ian McEwan's psrdnoise3.glsl (2021-12-02):
https://github.com/stegu/psrdnoise/blob/main/src/psrdnoise3.glsl
Specialized for the default axis-aligned grid, zero periods, and zero gradient
rotation. For animated 2D wind, sample at (x / size, y / size, time / duration)
and rotate the returned spatial gradient: (dy, -dx).
"""

# Copyright (c) 2021 Stefan Gustavson and Ian McEwan.
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

from std.math import cos, floor, max, min, sin, sqrt

comptime _Float4 = SIMD[DType.float32, 4]


@fieldwise_init
struct SimplexSample(TrivialRegisterPassable):
    """Noise value and its partial derivatives in the input coordinate system.
    """

    var value: Float32
    """Scalar noise value, scaled to approximately [-1, 1]."""
    var dx: Float32
    """Partial derivative with respect to the first input coordinate."""
    var dy: Float32
    """Partial derivative with respect to the second input coordinate."""
    var dz: Float32
    """Partial derivative with respect to the third input coordinate."""


@always_inline
def _permute(value: _Float4) -> _Float4:
    """Hashes four lattice coordinates with the reference permutation.

    Args:
        value: Integer-valued coordinates represented as Float32 lanes.

    Returns:
        Four hash values in [0, 289), using floor-based GLSL modulo.
    """
    var wrapped = value - floor(value / 289.0) * 289.0
    var polynomial = ((wrapped * 34.0) + 10.0) * wrapped
    return polynomial - floor(polynomial / 289.0) * 289.0


@always_inline
def simplex_noise3(x: Float32, y: Float32, z: Float32) -> SimplexSample:
    """Evaluates deterministic 3D simplex noise and its analytic gradient.

    Uses Float32 arithmetic without allocation, mutable global state, or
    device-specific operations. The same function can run on CPU or GPU.

    Args:
        x: First noise coordinate.
        y: Second noise coordinate.
        z: Third noise coordinate; use scaled elapsed time for 2D animation.

    Returns:
        Noise value and derivatives with respect to x, y, and z. Derivatives
        are with respect to these inputs, before any caller-applied scaling.
    """
    # Transform to the axis-aligned tetrahedral grid.
    var u = y + z
    var v = x + z
    var w = x + y
    var iu = floor(u)
    var iv = floor(v)
    var iw = floor(w)
    var fu = u - iu
    var fv = v - iv
    var fw = w - iw

    # Match GLSL step(edge, value), including ties on simplex boundaries.
    var step_uv: Float32 = 1.0 if fv >= fu else 0.0
    var step_uw: Float32 = 1.0 if fw >= fu else 0.0
    var step_vw: Float32 = 1.0 if fw >= fv else 0.0
    var gx = 1.0 - step_uw
    var gy = step_uv
    var gz = step_vw
    var lx = 1.0 - step_uv
    var ly = 1.0 - step_vw
    var lz = step_uw

    # Each lane represents one of the four simplex corners.
    var cu = iu + _Float4(0.0, min(gx, lx), max(gx, lx), 1.0)
    var cv = iv + _Float4(0.0, min(gy, ly), max(gy, ly), 1.0)
    var cw = iw + _Float4(0.0, min(gz, lz), max(gz, lz), 1.0)

    # Transform corners back to input coordinates and measure offsets.
    var ox = x - 0.5 * (-cu + cv + cw)
    var oy = y - 0.5 * (cu - cv + cw)
    var oz = z - 0.5 * (cu + cv - cw)

    var hashes = _permute(_permute(_permute(cw) + cv) + cu)

    # Generate fixed gradient directions on a Fibonacci sphere (alpha = 0).
    var theta = hashes * 3.883222077
    var gradient_z = hashes * -0.006920415 + 0.996539792
    var radius = sqrt(1.0 - gradient_z * gradient_z)
    var gradient_x = cos(theta) * radius
    var gradient_y = sin(theta) * radius

    var weight = max(0.5 - (ox * ox + oy * oy + oz * oz), _Float4(0.0))
    var weight2 = weight * weight
    var weight3 = weight2 * weight
    var ramp = gradient_x * ox + gradient_y * oy + gradient_z * oz
    var decay_derivative = -6.0 * weight2 * ramp

    return SimplexSample(
        39.5 * (weight3 * ramp).reduce_add(),
        39.5 * (weight3 * gradient_x + decay_derivative * ox).reduce_add(),
        39.5 * (weight3 * gradient_y + decay_derivative * oy).reduce_add(),
        39.5 * (weight3 * gradient_z + decay_derivative * oz).reduce_add(),
    )
