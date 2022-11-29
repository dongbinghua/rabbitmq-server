load("@rules_erlang//:erlang_bytecode2.bzl", "erlang_bytecode")
load("@rules_erlang//:filegroup.bzl", "filegroup")

def all_beam_files(name = "all_beam_files"):
    filegroup(
        name = "beam_files",
        srcs = ["ebin/rabbit_stream_core.beam"],
    )
    erlang_bytecode(
        name = "ebin_rabbit_stream_core_beam",
        srcs = ["src/rabbit_stream_core.erl"],
        outs = ["ebin/rabbit_stream_core.beam"],
        hdrs = ["include/rabbit_stream.hrl"],
        erlc_opts = "//:erlc_opts",
    )

def all_test_beam_files(name = "all_test_beam_files"):
    filegroup(
        name = "test_beam_files",
        testonly = True,
        srcs = ["test/rabbit_stream_core.beam"],
    )
    erlang_bytecode(
        name = "test_rabbit_stream_core_beam",
        testonly = True,
        srcs = ["src/rabbit_stream_core.erl"],
        outs = ["test/rabbit_stream_core.beam"],
        hdrs = ["include/rabbit_stream.hrl"],
        erlc_opts = "//:test_erlc_opts",
    )

def all_srcs(name = "all_srcs"):
    filegroup(
        name = "all_srcs",
        srcs = [":public_and_private_hdrs", ":srcs"],
    )
    filegroup(
        name = "public_and_private_hdrs",
        srcs = [":private_hdrs", ":public_hdrs"],
    )
    filegroup(
        name = "licenses",
        srcs = ["LICENSE", "LICENSE-MPL-RabbitMQ"],
    )
    filegroup(
        name = "priv",
        srcs = [],
    )

    filegroup(
        name = "srcs",
        srcs = ["src/rabbit_stream_core.erl"],
    )
    filegroup(
        name = "public_hdrs",
        srcs = ["include/rabbit_stream.hrl"],
    )
    filegroup(
        name = "private_hdrs",
        srcs = [],
    )

def test_suite_beam_files(name = "test_suite_beam_files"):
    erlang_bytecode(
        name = "rabbit_stream_core_SUITE_beam_files",
        testonly = True,
        srcs = ["test/rabbit_stream_core_SUITE.erl"],
        outs = ["test/rabbit_stream_core_SUITE.beam"],
        hdrs = ["include/rabbit_stream.hrl"],
        erlc_opts = "//:test_erlc_opts",
    )
