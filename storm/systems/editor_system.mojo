"""EditorSystem: edits obstacles from mouse and keyboard input."""

from std.math import cos, floor, sin
from larecs import Entity, Filter, System, SystemContext
from storm.components import Obstacle, Position
from storm.periodic import wrap_delta
from storm.resources import Bounds, Editor, Input, MAX_OBSTACLES, Time
from storm.scene import next_obstacle_group, obstacle_contains


comptime _MIN_HALF_SIZE: Float32 = 0.5
"""Smallest half size or radius the wheel can scale a shape to, in meters."""
comptime _MAX_HALF_SIZE: Float32 = 25.0
"""Largest half size or radius the wheel can scale a shape to, in meters."""
comptime _ROTATION_SPEED: Float32 = 1.5
"""Rotation speed while Q or E is held, in radians per second."""
comptime _SCALE_STEP: Float32 = 1.1
"""Size factor per wheel notch."""


@fieldwise_init
struct _Part(Copyable):
    """One obstacle shape entity with its current components."""

    var entity: Entity
    var position: Position
    var obstacle: Obstacle


def _wrap(value: Float32, extent: Float32) -> Float32:
    """Wraps a coordinate into `[0, extent)`.

    Args:
        value: Coordinate in meters.
        extent: Positive domain extent in meters.

    Returns:
        Equivalent coordinate inside the domain.
    """
    return value - floor(value / extent) * extent


struct EditorSystem(System):
    """Creates, moves, rotates, resizes, and deletes obstacles with the mouse.

    Controls, read from the Input resource:

    - `1` / `2`: choose the circle or rectangle tool.
    - Left click on empty space: create a shape and start dragging it.
    - Left drag on an obstacle: move all shapes of its group.
    - Mouse wheel: resize the hovered or dragged group around its center.
    - `Q` / `E` held: rotate the hovered or dragged group.
    - Right click or Delete: remove the hovered group.

    Runs before ObstacleSystem, so edits reach the kernels in the same frame.
    """

    var dragging: Int
    """Group being dragged, or -1."""
    var last_mouse: Position
    """Cursor position at the previous drag step."""

    def __init__(out self):
        """Creates an idle editor."""
        self.dragging = -1
        self.last_mouse = Position(0, 0)

    def initialize(mut self, mut context: SystemContext[...]) raises:
        """Adds the Input and Editor resources if they are missing.

        Args:
            context: World to edit.

        Raises:
            Error: If adding a resource fails.
        """
        ref resources = context.world[].resources
        if not resources.has[Input]():
            resources.add(Input())
        if not resources.has[Editor]():
            resources.add(Editor())

    def update(mut self, mut context: SystemContext[...]) raises:
        """Applies the last frame's input to the obstacle entities.

        Args:
            context: World containing obstacle entities and the Input, Editor,
                Bounds, and Time resources.

        Raises:
            Error: If a resource is missing or an entity edit fails.
        """
        ref resources = context.world[].resources
        var input = resources.read[Input]().copy()
        var bounds = resources.read[Bounds]()
        var dt = resources.read[Time]().dt
        var editor = resources.read[Editor]().copy()
        if input.tool == 1:
            editor.tool = Obstacle.CIRCLE
        elif input.tool == 2:
            editor.tool = Obstacle.RECTANGLE

        var parts = List[_Part]()
        for entity in context.world[].storage.query[
            Filter().read[Position, Obstacle]()
        ]():
            parts.append(
                _Part(
                    entity.get_entity(),
                    entity.get[Position](),
                    entity.get[Obstacle](),
                )
            )
        var hovered = -1
        if input.over_domain:
            # Later shapes are drawn on top, so the last hit wins.
            for part in parts:
                if obstacle_contains(
                    part.obstacle, part.position, input.mouse, bounds
                ):
                    hovered = part.obstacle.group

        if self.dragging >= 0 and not input.left_down:
            self.dragging = -1
        if self.dragging >= 0:
            var dx = wrap_delta(input.mouse.x - self.last_mouse.x, bounds.width)
            var dy = wrap_delta(
                input.mouse.y - self.last_mouse.y, bounds.height
            )
            self._transform(context, parts, self.dragging, dx, dy, 0, 1)
            self.last_mouse = input.mouse
        elif input.left_pressed and input.over_domain:
            if hovered >= 0:
                self.dragging = hovered
            elif len(parts) >= MAX_OBSTACLES:
                editor.message = String(
                    "Limit reached: at most ", MAX_OBSTACLES, " shapes"
                )
            else:
                var group = next_obstacle_group(context.world[])
                var shape = Obstacle.circle(4, group)
                if editor.tool == Obstacle.RECTANGLE:
                    shape = Obstacle.rectangle(14, 3, 0, group)
                _ = context.world[].storage.add_entity(input.mouse, shape)
                self.dragging = group
                editor.message = String()
            self.last_mouse = input.mouse

        var target = self.dragging if self.dragging >= 0 else hovered
        if target >= 0 and (input.right_pressed or input.delete_pressed):
            for part in parts:
                if part.obstacle.group == target:
                    context.world[].storage.remove_entity(part.entity)
            if self.dragging == target:
                self.dragging = -1
            target = -1
            editor.message = String()
        if target >= 0 and (input.wheel != 0 or input.rotation != 0):
            var scale = _SCALE_STEP**input.wheel
            if not self._fits(parts, target, scale):
                editor.message = String("Size limit reached")
                scale = 1
            self._transform(
                context,
                parts,
                target,
                0,
                0,
                input.rotation * _ROTATION_SPEED * dt,
                scale,
            )
        editor.hovered = target
        resources.set(editor^)

    @staticmethod
    def _fits(parts: List[_Part], group: Int, scale: Float32) -> Bool:
        """Returns whether scaling a group keeps every shape within limits.

        Args:
            parts: All obstacle shapes.
            group: Group to scale.
            scale: Size factor.

        Returns:
            True if every scaled half size lies in the allowed range.
        """
        for part in parts:
            if part.obstacle.group != group:
                continue
            for size in [part.obstacle.half_width, part.obstacle.half_height]:
                var scaled = size * scale
                if scaled < _MIN_HALF_SIZE or scaled > _MAX_HALF_SIZE:
                    return False
        return True

    @staticmethod
    def _transform(
        mut context: SystemContext[...],
        parts: List[_Part],
        group: Int,
        dx: Float32,
        dy: Float32,
        angle: Float32,
        scale: Float32,
    ) raises:
        """Moves, rotates, and scales a group around its center.

        Args:
            context: World containing the group's entities.
            parts: All obstacle shapes as read this frame.
            group: Group to transform.
            dx: Translation along x in meters.
            dy: Translation along y in meters.
            angle: Rotation in radians around the group center.
            scale: Size factor around the group center.

        Raises:
            Error: If updating an entity fails.
        """
        ref bounds = context.world[].resources.read[Bounds]()
        # Average wrapped offsets from the first part, so groups that cross
        # the domain edge keep a sensible center.
        var anchor = Position(0, 0)
        var count = 0
        var sum_x: Float32 = 0
        var sum_y: Float32 = 0
        for part in parts:
            if part.obstacle.group != group:
                continue
            if count == 0:
                anchor = part.position
            sum_x += wrap_delta(part.position.x - anchor.x, bounds.width)
            sum_y += wrap_delta(part.position.y - anchor.y, bounds.height)
            count += 1
        if count == 0:
            return
        var cx = anchor.x + sum_x / Float32(count)
        var cy = anchor.y + sum_y / Float32(count)
        var c = cos(angle)
        var s = sin(angle)
        for part in parts:
            if part.obstacle.group != group:
                continue
            var ox = wrap_delta(part.position.x - cx, bounds.width) * scale
            var oy = wrap_delta(part.position.y - cy, bounds.height) * scale
            context.world[].storage.get[Position](part.entity) = Position(
                _wrap(cx + dx + c * ox - s * oy, bounds.width),
                _wrap(cy + dy + s * ox + c * oy, bounds.height),
            )
            ref obstacle = context.world[].storage.get[Obstacle](part.entity)
            obstacle.half_width *= scale
            obstacle.half_height *= scale
            obstacle.angle += angle
