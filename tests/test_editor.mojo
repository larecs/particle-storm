"""Drives EditorSystem with scripted input and checks the obstacle entities."""

from std.math import pi
from std.testing import assert_almost_equal, assert_equal, assert_true
from larecs import Filter, SystemContext, World
from storm.components import Obstacle, Position
from storm.resources import Bounds, Editor, Input, MAX_OBSTACLES, Time
from storm.scene import ObstacleBuilder
from storm.systems import EditorSystem


comptime EditorWorld = World[Position, Obstacle]


def step(
    mut context: SystemContext[...], mut editor: EditorSystem, var input: Input
) raises:
    """Publishes one frame of input and runs the editor.

    Args:
        context: World being edited.
        editor: Editor under test.
        input: Input of the frame.

    Raises:
        Error: If the editor fails.
    """
    input.over_domain = True
    context.world[].resources.set(input^)
    editor.update(context)


def click(x: Float32, y: Float32, *, down: Bool = True) -> Input:
    """Creates input for a left press at a position.

    Args:
        x: Cursor x in meters.
        y: Cursor y in meters.
        down: Whether the button stays held.

    Returns:
        Input with the press.
    """
    var input = hover(x, y)
    input.left_pressed = True
    input.left_down = down
    return input^


def hover(x: Float32, y: Float32) -> Input:
    """Creates input with only the cursor position set.

    Args:
        x: Cursor x in meters.
        y: Cursor y in meters.

    Returns:
        Idle input at the position.
    """
    var input = Input()
    input.mouse = Position(x, y)
    return input^


def shapes(mut world: EditorWorld) raises -> List[Tuple[Position, Obstacle]]:
    """Returns every obstacle shape with its position.

    Args:
        world: World to read.

    Raises:
        Error: If querying fails.

    Returns:
        Positions and shapes in storage order.
    """
    var result = List[Tuple[Position, Obstacle]]()
    for entity in world.storage.query[Filter().read[Position, Obstacle]()]():
        result.append((entity.get[Position](), entity.get[Obstacle]()))
    return result^


def main() raises:
    """Runs the editor checks.

    Raises:
        Error: If a check fails.
    """
    var world = EditorWorld()
    world.resources.add(Bounds())
    world.resources.add(Time())
    var context = SystemContext(world)
    var editor = EditorSystem()
    editor.initialize(context)

    # A click on empty space creates a circle and starts dragging it.
    step(context, editor, click(20, 20))
    var found = shapes(context.world[])
    assert_equal(len(found), 1)
    assert_equal(found[0][1].shape, Obstacle.CIRCLE)
    var circle_group = found[0][1].group
    assert_equal(context.world[].resources.read[Editor]().hovered, circle_group)
    var drag = hover(30, 25)
    drag.left_down = True
    step(context, editor, drag^)
    found = shapes(context.world[])
    assert_equal(found[0][0].x, 30)
    assert_equal(found[0][0].y, 25)
    # Releasing ends the drag; moving the cursor away clears the hover.
    step(context, editor, hover(100, 70))
    assert_equal(context.world[].resources.read[Editor]().hovered, -1)

    # Key 2 selects rectangles; resize and rotate the hovered rectangle.
    var choose = hover(80, 40)
    choose.tool = 2
    step(context, editor, choose^)
    step(context, editor, click(80, 40, down=False))
    var transform = hover(80, 40)
    transform.wheel = 1
    transform.rotation = 1
    step(context, editor, transform^)
    found = shapes(context.world[])
    assert_equal(len(found), 2)
    ref rectangle = found[1][1]
    assert_equal(rectangle.shape, Obstacle.RECTANGLE)
    assert_almost_equal(rectangle.half_width, 7 * 1.1, atol=1e-5)
    assert_almost_equal(rectangle.half_height, 1.5 * 1.1, atol=1e-5)
    assert_almost_equal(rectangle.angle, 1.5 / 60.0, atol=1e-5)

    # Groups move and rotate as a whole around their center.
    var group = (
        ObstacleBuilder(60, 60)
        .circle(-5, 0, radius=1)
        .circle(5, 0, radius=1)
        .spawn(context.world[])
    )
    step(context, editor, click(55, 60))
    var move = hover(57, 62)
    move.left_down = True
    step(context, editor, move^)
    var turn = hover(57, 62)
    turn.left_down = True
    context.world[].resources.get[Time]().dt = Float32(pi / 2) / 1.5
    turn.rotation = 1
    step(context, editor, turn^)
    context.world[].resources.get[Time]().dt = 1.0 / 60.0
    var xs = List[Float32]()
    for item in shapes(context.world[]):
        if item[1].group == group:
            xs.append(item[0].x)
            # A quarter turn around (62, 62) puts both parts at x = 62.
            assert_almost_equal(item[0].x, 62, atol=1e-4)
    assert_equal(len(xs), 2)
    step(context, editor, hover(62, 57))

    # Right click deletes the whole group under the cursor.
    var delete = hover(62, 57)
    delete.right_pressed = True
    step(context, editor, delete^)
    for item in shapes(context.world[]):
        assert_true(item[1].group != group, "group not deleted")
    assert_equal(len(shapes(context.world[])), 2)

    # Clicks beyond the shape limit are rejected with a message.
    var circles = hover(100, 70)
    circles.tool = 1
    step(context, editor, circles^)
    for i in range(MAX_OBSTACLES - 2):
        var x = Float32(6 + 9 * (i % 12))
        var y = Float32(5 + 10 * (i // 12))
        step(context, editor, click(x, y, down=False))
    assert_equal(len(shapes(context.world[])), MAX_OBSTACLES)
    step(context, editor, click(60, 45, down=False))
    assert_equal(len(shapes(context.world[])), MAX_OBSTACLES)
    assert_true("Limit" in context.world[].resources.read[Editor]().message)
    print("PASS: create, drag, tools, resize, rotate, groups, delete, limit")
