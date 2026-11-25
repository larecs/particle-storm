"""Composes obstacle entities from rotated circles and rectangles."""

from std.math import cos, sin
from larecs import Filter, World
from storm.components import Obstacle, Position
from storm.periodic import wrap_delta
from storm.resources import Bounds, Obstacles


struct ObstacleBuilder(Movable):
    """Composes one obstacle from circles and rectangles, then spawns it.

    Parts are placed at offsets from the builder's origin. The builder's
    rotation turns the whole group, and each rectangle can add its own
    rotation. Angles are in radians and turn clockwise on screen, because y
    points down. Every part becomes one entity with `Position` and `Obstacle`;
    all parts share a new group id, so the editor moves them together.

    Examples:

    ```mojo
    # A barrier with rounded ends, tilted by 0.35 rad.
    _ = (
        ObstacleBuilder(62, 30, angle=0.35)
        .rectangle(0, 0, width=22, height=3)
        .circle(-11, 0, radius=3)
        .circle(11, 0, radius=3)
        .spawn(world)
    )
    ```
    """

    var x: Float32
    var y: Float32
    var angle: Float32
    var positions: List[Position]
    var shapes: List[Obstacle]

    def __init__(out self, x: Float32, y: Float32, *, angle: Float32 = 0):
        """Starts an obstacle with its origin and rotation.

        Args:
            x: Origin x coordinate in meters.
            y: Origin y coordinate in meters.
            angle: Rotation of the whole obstacle in radians.
        """
        self.x = x
        self.y = y
        self.angle = angle
        self.positions = List[Position]()
        self.shapes = List[Obstacle]()

    def _place(mut self, dx: Float32, dy: Float32, shape: Obstacle) raises:
        """Rotates a local offset around the origin and records a part.

        Args:
            dx: Local x offset in meters.
            dy: Local y offset in meters.
            shape: Part shape in local orientation.

        Raises:
            Error: If the shape is invalid.
        """
        shape.validate()
        var c = cos(self.angle)
        var s = sin(self.angle)
        self.positions.append(
            Position(self.x + c * dx - s * dy, self.y + s * dx + c * dy)
        )
        var placed = shape
        placed.angle += self.angle
        self.shapes.append(placed)

    def circle(
        var self, dx: Float32, dy: Float32, *, radius: Float32
    ) raises -> Self:
        """Adds a circle.

        Args:
            dx: Local x offset of the center in meters.
            dy: Local y offset of the center in meters.
            radius: Positive radius in meters.

        Raises:
            Error: If the radius is not positive.

        Returns:
            The builder, for chaining.
        """
        self._place(dx, dy, Obstacle.circle(radius))
        return self^

    def rectangle(
        var self,
        dx: Float32,
        dy: Float32,
        *,
        width: Float32,
        height: Float32,
        angle: Float32 = 0,
    ) raises -> Self:
        """Adds a rectangle.

        Args:
            dx: Local x offset of the center in meters.
            dy: Local y offset of the center in meters.
            width: Positive width along the local x axis in meters.
            height: Positive height along the local y axis in meters.
            angle: Extra rotation of this part in radians.

        Raises:
            Error: If width or height is not positive.

        Returns:
            The builder, for chaining.
        """
        self._place(dx, dy, Obstacle.rectangle(width, height, angle))
        return self^

    def spawn(self, mut world: World[...]) raises -> Int:
        """Adds one entity per part to a world.

        Args:
            world: World whose components include Position and Obstacle.

        Raises:
            Error: If the obstacle has no parts or adding an entity fails.

        Returns:
            Group id shared by all spawned parts.
        """
        if len(self.shapes) == 0:
            raise Error("An obstacle needs at least one shape")
        var group = next_obstacle_group(world)
        for i in range(len(self.shapes)):
            var shape = self.shapes[i]
            shape.group = group
            _ = world.storage.add_entity(self.positions[i], shape)
        return group


def next_obstacle_group(mut world: World[...]) raises -> Int:
    """Returns a group id that no obstacle in the world uses yet.

    Args:
        world: World whose components include Obstacle.

    Raises:
        Error: If querying the world fails.

    Returns:
        One more than the largest group id, or 1 for a world without
        obstacles.
    """
    var largest = 0
    for entity in world.storage.query[Filter().read[Obstacle]()]():
        largest = max(largest, entity.get[Obstacle]().group)
    return largest + 1


def obstacle_contains(
    obstacle: Obstacle, center: Position, point: Position, bounds: Bounds
) raises -> Bool:
    """Returns whether a point lies inside one obstacle shape.

    Args:
        obstacle: Shape to test.
        center: Shape center in meters.
        point: Point to test in meters.
        bounds: Periodic domain size.

    Raises:
        Error: If the shape is invalid.

    Returns:
        True if the point is inside or on the shape.
    """
    var single = Obstacles()
    single.add(center, obstacle)
    var dx = wrap_delta(point.x - center.x, bounds.width)
    var dy = wrap_delta(point.y - center.y, bounds.height)
    return single._contact[0](dx, dy).distance <= 0
