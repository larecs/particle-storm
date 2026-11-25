"""Distances on the periodic domain."""

from std.math import floor


@always_inline
def wrap_delta(delta: Float32, extent: Float32) -> Float32:
    """Returns the shortest periodic offset along one axis.

    Args:
        delta: Raw coordinate difference in meters.
        extent: Positive domain extent along the axis in meters.

    Returns:
        Offset in `[-extent / 2, extent / 2)` equivalent to `delta`.
    """
    return delta - floor(delta / extent + 0.5) * extent
