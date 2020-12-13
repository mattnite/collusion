const Builder = @import("std").build.Builder;
const pkgs = @import("deps.zig").pkgs;

const mecha = pkgs.mecha;
const pike = pkgs.pike;
const zap = pkgs.zap;
const pam = pkgs.pam;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const server = b.addExecutable("collusion-server", "src/server.zig");
    server.setTarget(target);
    server.setBuildMode(mode);
    server.addPackage(pam);
    server.install();

    const client = b.addExecutable("collusion-client", "src/client.zig");
    client.setTarget(target);
    client.setBuildMode(mode);
    client.addPackage(pam);
    client.addPackage(mecha);
    client.install();

    const tests = b.addTest("src/protocol.zig");
    tests.setTarget(target);
    tests.setBuildMode(mode);
    tests.addPackage(pam);

    const run_cmd = server.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}
