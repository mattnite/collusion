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
    server.addPackage(pike);
    server.addPackage(zap);
    server.addPackage(pam);
    server.install();

    const client = b.addExecutable("collusion-client", "src/client.zig");
    client.setTarget(target);
    client.setBuildMode(mode);
    client.addPackage(mecha);
    client.addPackage(pike);
    client.addPackage(zap);
    client.install();

    const run_cmd = server.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
