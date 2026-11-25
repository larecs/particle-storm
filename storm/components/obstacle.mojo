"""Solid obstacle shape component."""


@fieldwise_init
struct Obstacle(ImplicitlyCopyable, Movable):
    """Marks an entity as a solid circle or rotated rectangle.

    The entity's Position is the shape's center. Use `ObstacleBuilder` to
    compose obstacles from several shapes.
    """

    var shape: Int
    """`CIRCLE` or `RECTANGLE`."""
    var half_width: Float32
    """Half width in meters, or the radius of a circle."""
    var half_height: Float32
    """Half height in meters; equal to the radius for a circle."""
    var angle: Float32
    """Rotation in radians, clockwise on screen because y points down."""
    var group: Int
    """Obstacle this shape belongs to; the editor moves a group as one."""

    comptime CIRCLE = 0
    comptime RECTANGLE = 1

    @staticmethod
    def circle(radius: Float32, group: Int = 0) -> Self:
        """Creates a circle.

        Args:
            radius: Positive radius in meters.
            group: Obstacle group of the shape.

        Returns:
            Circle shape.
        """
        return Self(Self.CIRCLE, radius, radius, 0, group)

    @staticmethod
    def rectangle(
        width: Float32, height: Float32, angle: Float32 = 0, group: Int = 0
    ) -> Self:
        """Creates a rectangle.

        Args:
            width: Positive width along the unrotated x axis in meters.
            height: Positive height along the unrotated y axis in meters.
            angle: Rotation in radians.
            group: Obstacle group of the shape.

        Returns:
            Rectangle shape.
        """
        return Self(Self.RECTANGLE, width / 2, height / 2, angle, group)

    def validate(self) raises:
        """Checks the shape kind and sizes.

        Raises:
            Error: If the kind is unknown or a size is not positive.
        """
        if self.shape != Self.CIRCLE and self.shape != Self.RECTANGLE:
            raise Error("Unknown obstacle shape")
        if not (self.half_width > 0 and self.half_height > 0):
            raise Error("Obstacle sizes must be positive")
