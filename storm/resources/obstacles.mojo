"""Obstacles resource: packed shapes that kernels read."""

from std.math import cos, sin, sqrt
from storm.components import Obstacle, Position, Velocity
from storm.periodic import wrap_delta
from storm.resources.bounds import Bounds
from storm.resources.storm import Wind


comptime MAX_OBSTACLES = 16
"""Capacity of the Obstacles resource."""


comptime _Lanes = SIMD[DType.float32, MAX_OBSTACLES]
"""One float per obstacle slot."""


@fieldwise_init
struct _Contact(TrivialRegisterPassable):
    """Signed distance to a shape's surface and the outward surface normal."""

    var distance: Float32
    """Meters outside the shape; negative inside."""
    var nx: Float32
    var ny: Float32


struct Obstacles(TrivialRegisterPassable):
    """Packed copy of up to MAX_OBSTACLES obstacle shapes for kernels.

    Kernels iterate particles only, so ObstacleSystem gathers the entities
    with an Obstacle component into this resource each frame. Shapes are
    circles or rotated rectangles; wind and collisions use each shape's
    signed distance and outward normal.
    """

    var x: _Lanes
    """Center x coordinates in meters."""
    var y: _Lanes
    """Center y coordinates in meters."""
    var half_width: _Lanes
    """Half widths, or radii for circles, in meters."""
    var half_height: _Lanes
    """Half heights in meters; equal to the radius for circles."""
    var cos_angle: _Lanes
    """Cosine of each rotation."""
    var sin_angle: _Lanes
    """Sine of each rotation."""
    var rectangle: _Lanes
    """1 for rectangles and 0 for circles; floats, since bool lanes crash
    Apple's Metal shader compiler when read in a kernel."""
    var size: _Lanes
    """Length scale of each shape's wind shadow in meters."""
    var extent: _Lanes
    """Distance from each center to its farthest surface point in meters."""
    var group: _Lanes
    """Obstacle group of each shape, for display highlighting."""
    var count: Int
    """Number of used entries."""
    var friction: Float32
    """Fraction of tangential velocity kept on contact."""

    def __init__(out self):
        """Creates an empty obstacle set."""
        self.x = 0
        self.y = 0
        self.half_width = 0
        self.half_height = 0
        self.cos_angle = 1
        self.sin_angle = 0
        self.rectangle = 0
        self.size = 0
        self.extent = 0
        self.group = -1
        self.count = 0
        self.friction = 0.8

    def add(mut self, position: Position, obstacle: Obstacle) raises:
        """Adds one obstacle shape.

        Args:
            position: Shape center in meters.
            obstacle: Shape, size, and rotation.

        Raises:
            Error: If the set is full or the shape is invalid.
        """
        if self.count >= MAX_OBSTACLES:
            raise Error("At most " + String(MAX_OBSTACLES) + " obstacles")
        obstacle.validate()
        var i = self.count
        self.x[i] = position.x
        self.y[i] = position.y
        self.half_width[i] = obstacle.half_width
        self.half_height[i] = obstacle.half_height
        self.cos_angle[i] = cos(obstacle.angle)
        self.sin_angle[i] = sin(obstacle.angle)
        var is_rectangle = obstacle.shape == Obstacle.RECTANGLE
        self.rectangle[i] = 1 if is_rectangle else 0
        self.group[i] = Float32(obstacle.group)
        if is_rectangle:
            self.size[i] = sqrt(obstacle.half_width * obstacle.half_height)
            self.extent[i] = sqrt(
                obstacle.half_width * obstacle.half_width
                + obstacle.half_height * obstacle.half_height
            )
        else:
            self.size[i] = obstacle.half_width
            self.extent[i] = obstacle.half_width
        self.count += 1

    def same_shapes(self, other: Self) -> Bool:
        """Returns whether both sets hold the same shapes in the same order.

        Args:
            other: Set to compare with.

        Returns:
            True if counts, placements, sizes, and shape kinds match.
        """
        return (
            self.count == other.count
            and self.x == other.x
            and self.y == other.y
            and self.half_width == other.half_width
            and self.half_height == other.half_height
            and self.cos_angle == other.cos_angle
            and self.sin_angle == other.sin_angle
            and self.rectangle == other.rectangle
            and self.group == other.group
        )

    @always_inline
    def _contact[i: Int](self, dx: Float32, dy: Float32) -> _Contact:
        """Returns the signed distance and outward normal of shape `i`.

        Parameters:
            i: Shape index below `count`.

        Args:
            dx: Wrapped x offset from the shape center in meters.
            dy: Wrapped y offset from the shape center in meters.

        Returns:
            Signed distance to the surface and the outward unit normal.
        """
        if self.rectangle[i] == 0:
            var d = sqrt(dx * dx + dy * dy)
            if d < 1e-6:
                return _Contact(-self.half_width[i], 0, -1)
            return _Contact(d - self.half_width[i], dx / d, dy / d)
        # Rotate into the rectangle's frame, measure, and rotate back.
        var c = self.cos_angle[i]
        var s = self.sin_angle[i]
        var lx = c * dx + s * dy
        var ly = c * dy - s * dx
        var qx = abs(lx) - self.half_width[i]
        var qy = abs(ly) - self.half_height[i]
        var sx: Float32 = 1 if lx >= 0 else -1
        var sy: Float32 = 1 if ly >= 0 else -1
        var distance: Float32
        var mx: Float32
        var my: Float32
        if qx > 0 or qy > 0:
            var ox = max(qx, 0)
            var oy = max(qy, 0)
            distance = sqrt(ox * ox + oy * oy)
            mx = sx * ox / distance
            my = sy * oy / distance
        elif qx > qy:
            distance = qx
            mx = sx
            my = 0
        else:
            distance = qy
            mx = 0
            my = sy
        return _Contact(distance, c * mx - s * my, s * mx + c * my)

    @always_inline
    def deflect(self, wind: Wind, position: Position, bounds: Bounds) -> Wind:
        """Bends wind around the obstacles.

        Near each shape, the wind is treated as locally uniform and scaled
        like potential flow past a cylinder: the component along the surface
        normal by `1 - s` and the tangential component by `1 + s`, with
        `s = (L / (L + d))²` for surface distance `d` and shape size `L`.
        For a circle `L` is the radius, which gives the exact cylinder flow;
        for a rectangle it is the geometric mean of the half extents. `s` is
        shifted to fall to zero at `d = 3L`, so the wind stays continuous.

        Args:
            wind: Undisturbed wind at the position.
            position: Sample position in meters.
            bounds: Periodic domain size.

        Returns:
            Deflected wind; zero inside an obstacle.
        """
        var result = wind
        # Unrolled with constant lane indices: dynamic SIMD indexing forces
        # GPU register spills.
        comptime for i in range(MAX_OBSTACLES):
            if i >= self.count:
                break
            var dx = wrap_delta(position.x - self.x[i], bounds.width)
            var dy = wrap_delta(position.y - self.y[i], bounds.height)
            var size = self.size[i]
            var reach = self.extent[i] + 3 * size
            if dx * dx + dy * dy >= reach * reach:
                continue
            var contact = self._contact[i](dx, dy)
            if contact.distance <= 0:
                return Wind(0, 0)
            var ratio = size / (size + contact.distance)
            var s = (ratio * ratio - 1.0 / 16.0) * (16.0 / 15.0)
            if s <= 0:
                continue
            var nx = contact.nx
            var ny = contact.ny
            var normal = (result.dx * nx + result.dy * ny) * (1 - s)
            var tangent = (result.dy * nx - result.dx * ny) * (1 + s)
            result = Wind(
                normal * nx - tangent * ny, normal * ny + tangent * nx
            )
        return result

    @always_inline
    def collide(
        self,
        mut position: Position,
        mut velocity: Velocity,
        bounds: Bounds,
        margin: Float32 = 0,
    ) -> Bool:
        """Moves a particle out of any obstacle and stops inward motion.

        Args:
            position: Particle position in meters, updated in place.
            velocity: Particle velocity in meters per second, updated in place.
            bounds: Periodic domain size.
            margin: Distance from a surface that still counts as touching,
                in meters.

        Returns:
            True if the particle was inside or is within `margin` of an
            obstacle.
        """
        var touching = False
        comptime for i in range(MAX_OBSTACLES):
            if i >= self.count:
                break
            var dx = wrap_delta(position.x - self.x[i], bounds.width)
            var dy = wrap_delta(position.y - self.y[i], bounds.height)
            var reach = self.extent[i] + margin
            if dx * dx + dy * dy >= reach * reach:
                continue
            var contact = self._contact[i](dx, dy)
            if contact.distance < margin:
                touching = True
            if contact.distance >= 0:
                continue
            position.x -= contact.nx * contact.distance
            position.y -= contact.ny * contact.distance
            var normal = velocity.dx * contact.nx + velocity.dy * contact.ny
            if normal < 0:
                velocity.dx -= normal * contact.nx
                velocity.dy -= normal * contact.ny
            velocity.dx *= self.friction
            velocity.dy *= self.friction
        return touching
