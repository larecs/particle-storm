"""Command-line options of the particle storm."""

from std.sys import argv


@fieldwise_init
struct Options(TrivialRegisterPassable):
    """Settings of one simulation run."""

    var on_gpu: Bool
    """Whether kernels run on an accelerator instead of CPU threads."""
    var frames: Int
    """Frames to run before stopping, or -1 for no limit."""
    var particles: Int
    """Number of particles to create."""

    @staticmethod
    def parse() raises -> Self:
        """Reads the options from the process arguments.

        Raises:
            Error: If an argument is unknown or a count is not positive.

        Returns:
            The parsed options.
        """
        var args = argv()
        var options = Self(on_gpu=False, frames=-1, particles=300_000)
        var i = 1
        while i < len(args):
            if args[i] == "--gpu":
                options.on_gpu = True
            elif args[i] == "--cpu":
                options.on_gpu = False
            elif args[i] == "--frames" or args[i] == "--particles":
                if i + 1 >= len(args):
                    raise Error("Expected a positive integer after " + args[i])
                var value = Int(args[i + 1])
                if value <= 0:
                    raise Error("Expected a positive integer after " + args[i])
                if args[i] == "--frames":
                    options.frames = value
                else:
                    options.particles = value
                i += 1
            else:
                raise Error(
                    "Usage: particles [--gpu | --cpu] [--frames N]"
                    " [--particles N]"
                )
            i += 1
        return options
