load("@rules_erlang//:erlang_bytecode2.bzl", "erlang_bytecode")
load("@rules_erlang//:filegroup.bzl", "filegroup")

def all_beam_files(name = "all_beam_files"):
    filegroup(
        name = "beam_files",
        srcs = ["ebin/rabbit_federation_mgmt.beam"],
    )
    erlang_bytecode(
        name = "ebin_rabbit_federation_mgmt_beam",
        srcs = ["src/rabbit_federation_mgmt.erl"],
        outs = ["ebin/rabbit_federation_mgmt.beam"],
        erlc_opts = "//:erlc_opts",
        deps = ["//deps/rabbitmq_management:erlang_app", "//deps/rabbitmq_management_agent:erlang_app"],
    )

def all_test_beam_files(name = "all_test_beam_files"):
    filegroup(
        name = "test_beam_files",
        testonly = True,
        srcs = ["test/rabbit_federation_mgmt.beam"],
    )
    erlang_bytecode(
        name = "test_rabbit_federation_mgmt_beam",
        testonly = True,
        srcs = ["src/rabbit_federation_mgmt.erl"],
        outs = ["test/rabbit_federation_mgmt.beam"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/rabbitmq_management:erlang_app", "//deps/rabbitmq_management_agent:erlang_app"],
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
        srcs = ["LICENSE", "LICENSE-APACHE2-ExplorerCanvas", "LICENSE-BSD-base64js", "LICENSE-MIT-EJS10", "LICENSE-MIT-Flot", "LICENSE-MIT-Sammy060", "LICENSE-MIT-jQuery164", "LICENSE-MPL-RabbitMQ"],
    )
    filegroup(
        name = "priv",
        srcs = ["priv/www/js/federation.js", "priv/www/js/tmpl/federation.ejs", "priv/www/js/tmpl/federation-upstream.ejs", "priv/www/js/tmpl/federation-upstreams.ejs"],
    )
    filegroup(
        name = "public_hdrs",
        srcs = [],
    )

    filegroup(
        name = "srcs",
        srcs = ["src/rabbit_federation_mgmt.erl"],
    )
    filegroup(
        name = "private_hdrs",
        srcs = [],
    )

def test_suite_beam_files(name = "test_suite_beam_files"):
    erlang_bytecode(
        name = "federation_mgmt_SUITE_beam_files",
        testonly = True,
        srcs = ["test/federation_mgmt_SUITE.erl"],
        outs = ["test/federation_mgmt_SUITE.beam"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/amqp_client:erlang_app", "//deps/rabbitmq_ct_helpers:erlang_app"],
    )
