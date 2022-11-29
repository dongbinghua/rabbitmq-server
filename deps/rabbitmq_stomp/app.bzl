load("@rules_erlang//:erlang_bytecode2.bzl", "erlang_bytecode")
load("@rules_erlang//:filegroup.bzl", "filegroup")

def all_beam_files(name = "all_beam_files"):
    filegroup(
        name = "beam_files",
        srcs = ["ebin/Elixir.RabbitMQ.CLI.Ctl.Commands.ListStompConnectionsCommand.beam", "ebin/rabbit_stomp.beam", "ebin/rabbit_stomp_client_sup.beam", "ebin/rabbit_stomp_connection_info.beam", "ebin/rabbit_stomp_frame.beam", "ebin/rabbit_stomp_internal_event_handler.beam", "ebin/rabbit_stomp_processor.beam", "ebin/rabbit_stomp_reader.beam", "ebin/rabbit_stomp_sup.beam", "ebin/rabbit_stomp_util.beam"],
    )
    erlang_bytecode(
        name = "ebin_Elixir_RabbitMQ_CLI_Ctl_Commands_ListStompConnectionsCommand_beam",
        srcs = ["src/Elixir.RabbitMQ.CLI.Ctl.Commands.ListStompConnectionsCommand.erl"],
        outs = ["ebin/Elixir.RabbitMQ.CLI.Ctl.Commands.ListStompConnectionsCommand.beam"],
        hdrs = ["include/rabbit_stomp.hrl"],
        erlc_opts = "//:erlc_opts",
        deps = ["//deps/rabbitmq_cli:erlang_app"],
    )
    erlang_bytecode(
        name = "ebin_rabbit_stomp_beam",
        srcs = ["src/rabbit_stomp.erl"],
        outs = ["ebin/rabbit_stomp.beam"],
        hdrs = ["include/rabbit_stomp.hrl"],
        erlc_opts = "//:erlc_opts",
    )
    erlang_bytecode(
        name = "ebin_rabbit_stomp_client_sup_beam",
        srcs = ["src/rabbit_stomp_client_sup.erl"],
        outs = ["ebin/rabbit_stomp_client_sup.beam"],
        erlc_opts = "//:erlc_opts",
        deps = ["//deps/rabbit_common:erlang_app", "@ranch//:erlang_app"],
    )
    erlang_bytecode(
        name = "ebin_rabbit_stomp_connection_info_beam",
        srcs = ["src/rabbit_stomp_connection_info.erl"],
        outs = ["ebin/rabbit_stomp_connection_info.beam"],
        erlc_opts = "//:erlc_opts",
    )
    erlang_bytecode(
        name = "ebin_rabbit_stomp_frame_beam",
        srcs = ["src/rabbit_stomp_frame.erl"],
        outs = ["ebin/rabbit_stomp_frame.beam"],
        hdrs = ["include/rabbit_stomp_frame.hrl", "include/rabbit_stomp_headers.hrl"],
        erlc_opts = "//:erlc_opts",
    )
    erlang_bytecode(
        name = "ebin_rabbit_stomp_internal_event_handler_beam",
        srcs = ["src/rabbit_stomp_internal_event_handler.erl"],
        outs = ["ebin/rabbit_stomp_internal_event_handler.beam"],
        erlc_opts = "//:erlc_opts",
    )
    erlang_bytecode(
        name = "ebin_rabbit_stomp_processor_beam",
        srcs = ["src/rabbit_stomp_processor.erl"],
        outs = ["ebin/rabbit_stomp_processor.beam"],
        hdrs = ["include/rabbit_stomp.hrl", "include/rabbit_stomp_frame.hrl", "include/rabbit_stomp_headers.hrl"],
        erlc_opts = "//:erlc_opts",
        deps = ["//deps/amqp_client:erlang_app"],
    )
    erlang_bytecode(
        name = "ebin_rabbit_stomp_reader_beam",
        srcs = ["src/rabbit_stomp_reader.erl"],
        outs = ["ebin/rabbit_stomp_reader.beam"],
        hdrs = ["include/rabbit_stomp.hrl", "include/rabbit_stomp_frame.hrl"],
        erlc_opts = "//:erlc_opts",
        deps = ["//deps/amqp_client:erlang_app", "//deps/rabbit_common:erlang_app"],
    )
    erlang_bytecode(
        name = "ebin_rabbit_stomp_sup_beam",
        srcs = ["src/rabbit_stomp_sup.erl"],
        outs = ["ebin/rabbit_stomp_sup.beam"],
        erlc_opts = "//:erlc_opts",
    )
    erlang_bytecode(
        name = "ebin_rabbit_stomp_util_beam",
        srcs = ["src/rabbit_stomp_util.erl"],
        outs = ["ebin/rabbit_stomp_util.beam"],
        hdrs = ["include/rabbit_stomp_frame.hrl", "include/rabbit_stomp_headers.hrl"],
        erlc_opts = "//:erlc_opts",
        deps = ["//deps/amqp_client:erlang_app"],
    )

def all_test_beam_files(name = "all_test_beam_files"):
    erlang_bytecode(
        name = "test_Elixir_RabbitMQ_CLI_Ctl_Commands_ListStompConnectionsCommand_beam",
        testonly = True,
        srcs = ["src/Elixir.RabbitMQ.CLI.Ctl.Commands.ListStompConnectionsCommand.erl"],
        outs = ["test/Elixir.RabbitMQ.CLI.Ctl.Commands.ListStompConnectionsCommand.beam"],
        hdrs = ["include/rabbit_stomp.hrl"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/rabbitmq_cli:erlang_app"],
    )
    filegroup(
        name = "test_beam_files",
        testonly = True,
        srcs = ["test/Elixir.RabbitMQ.CLI.Ctl.Commands.ListStompConnectionsCommand.beam", "test/rabbit_stomp.beam", "test/rabbit_stomp_client_sup.beam", "test/rabbit_stomp_connection_info.beam", "test/rabbit_stomp_frame.beam", "test/rabbit_stomp_internal_event_handler.beam", "test/rabbit_stomp_processor.beam", "test/rabbit_stomp_reader.beam", "test/rabbit_stomp_sup.beam", "test/rabbit_stomp_util.beam"],
    )
    erlang_bytecode(
        name = "test_rabbit_stomp_beam",
        testonly = True,
        srcs = ["src/rabbit_stomp.erl"],
        outs = ["test/rabbit_stomp.beam"],
        hdrs = ["include/rabbit_stomp.hrl"],
        erlc_opts = "//:test_erlc_opts",
    )
    erlang_bytecode(
        name = "test_rabbit_stomp_client_sup_beam",
        testonly = True,
        srcs = ["src/rabbit_stomp_client_sup.erl"],
        outs = ["test/rabbit_stomp_client_sup.beam"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/rabbit_common:erlang_app", "@ranch//:erlang_app"],
    )
    erlang_bytecode(
        name = "test_rabbit_stomp_connection_info_beam",
        testonly = True,
        srcs = ["src/rabbit_stomp_connection_info.erl"],
        outs = ["test/rabbit_stomp_connection_info.beam"],
        erlc_opts = "//:test_erlc_opts",
    )
    erlang_bytecode(
        name = "test_rabbit_stomp_frame_beam",
        testonly = True,
        srcs = ["src/rabbit_stomp_frame.erl"],
        outs = ["test/rabbit_stomp_frame.beam"],
        hdrs = ["include/rabbit_stomp_frame.hrl", "include/rabbit_stomp_headers.hrl"],
        erlc_opts = "//:test_erlc_opts",
    )
    erlang_bytecode(
        name = "test_rabbit_stomp_internal_event_handler_beam",
        testonly = True,
        srcs = ["src/rabbit_stomp_internal_event_handler.erl"],
        outs = ["test/rabbit_stomp_internal_event_handler.beam"],
        erlc_opts = "//:test_erlc_opts",
    )
    erlang_bytecode(
        name = "test_rabbit_stomp_processor_beam",
        testonly = True,
        srcs = ["src/rabbit_stomp_processor.erl"],
        outs = ["test/rabbit_stomp_processor.beam"],
        hdrs = ["include/rabbit_stomp.hrl", "include/rabbit_stomp_frame.hrl", "include/rabbit_stomp_headers.hrl"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/amqp_client:erlang_app"],
    )
    erlang_bytecode(
        name = "test_rabbit_stomp_reader_beam",
        testonly = True,
        srcs = ["src/rabbit_stomp_reader.erl"],
        outs = ["test/rabbit_stomp_reader.beam"],
        hdrs = ["include/rabbit_stomp.hrl", "include/rabbit_stomp_frame.hrl"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/amqp_client:erlang_app", "//deps/rabbit_common:erlang_app"],
    )
    erlang_bytecode(
        name = "test_rabbit_stomp_sup_beam",
        testonly = True,
        srcs = ["src/rabbit_stomp_sup.erl"],
        outs = ["test/rabbit_stomp_sup.beam"],
        erlc_opts = "//:test_erlc_opts",
    )
    erlang_bytecode(
        name = "test_rabbit_stomp_util_beam",
        testonly = True,
        srcs = ["src/rabbit_stomp_util.erl"],
        outs = ["test/rabbit_stomp_util.beam"],
        hdrs = ["include/rabbit_stomp_frame.hrl", "include/rabbit_stomp_headers.hrl"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/amqp_client:erlang_app"],
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
        srcs = ["priv/schema/rabbitmq_stomp.schema"],
    )
    filegroup(
        name = "private_hdrs",
        srcs = [],
    )
    filegroup(
        name = "srcs",
        srcs = ["src/Elixir.RabbitMQ.CLI.Ctl.Commands.ListStompConnectionsCommand.erl", "src/rabbit_stomp.erl", "src/rabbit_stomp_client_sup.erl", "src/rabbit_stomp_connection_info.erl", "src/rabbit_stomp_frame.erl", "src/rabbit_stomp_internal_event_handler.erl", "src/rabbit_stomp_processor.erl", "src/rabbit_stomp_reader.erl", "src/rabbit_stomp_sup.erl", "src/rabbit_stomp_util.erl"],
    )
    filegroup(
        name = "public_hdrs",
        srcs = ["include/rabbit_stomp.hrl", "include/rabbit_stomp_frame.hrl", "include/rabbit_stomp_headers.hrl"],
    )

def test_suite_beam_files(name = "test_suite_beam_files"):
    erlang_bytecode(
        name = "command_SUITE_beam_files",
        testonly = True,
        srcs = ["test/command_SUITE.erl"],
        outs = ["test/command_SUITE.beam"],
        hdrs = ["include/rabbit_stomp.hrl"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/amqp_client:erlang_app"],
    )
    erlang_bytecode(
        name = "config_schema_SUITE_beam_files",
        testonly = True,
        srcs = ["test/config_schema_SUITE.erl"],
        outs = ["test/config_schema_SUITE.beam"],
        erlc_opts = "//:test_erlc_opts",
    )
    erlang_bytecode(
        name = "connections_SUITE_beam_files",
        testonly = True,
        srcs = ["test/connections_SUITE.erl"],
        outs = ["test/connections_SUITE.beam"],
        hdrs = ["include/rabbit_stomp_frame.hrl"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/amqp_client:erlang_app"],
    )
    erlang_bytecode(
        name = "frame_SUITE_beam_files",
        testonly = True,
        srcs = ["test/frame_SUITE.erl"],
        outs = ["test/frame_SUITE.beam"],
        hdrs = ["include/rabbit_stomp_frame.hrl", "include/rabbit_stomp_headers.hrl"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/amqp_client:erlang_app"],
    )
    erlang_bytecode(
        name = "proxy_protocol_SUITE_beam_files",
        testonly = True,
        srcs = ["test/proxy_protocol_SUITE.erl"],
        outs = ["test/proxy_protocol_SUITE.beam"],
        erlc_opts = "//:test_erlc_opts",
    )
    erlang_bytecode(
        name = "python_SUITE_beam_files",
        testonly = True,
        srcs = ["test/python_SUITE.erl"],
        outs = ["test/python_SUITE.beam"],
        erlc_opts = "//:test_erlc_opts",
    )
    erlang_bytecode(
        name = "system_SUITE_beam_files",
        testonly = True,
        srcs = ["test/system_SUITE.erl"],
        outs = ["test/system_SUITE.beam"],
        hdrs = ["include/rabbit_stomp.hrl", "include/rabbit_stomp_frame.hrl", "include/rabbit_stomp_headers.hrl"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/amqp_client:erlang_app"],
    )
    erlang_bytecode(
        name = "test_src_rabbit_stomp_client_beam",
        testonly = True,
        srcs = ["test/src/rabbit_stomp_client.erl"],
        outs = ["test/src/rabbit_stomp_client.beam"],
        hdrs = ["include/rabbit_stomp_frame.hrl"],
        erlc_opts = "//:test_erlc_opts",
    )
    erlang_bytecode(
        name = "test_src_rabbit_stomp_publish_test_beam",
        testonly = True,
        srcs = ["test/src/rabbit_stomp_publish_test.erl"],
        outs = ["test/src/rabbit_stomp_publish_test.beam"],
        hdrs = ["include/rabbit_stomp_frame.hrl"],
        erlc_opts = "//:test_erlc_opts",
    )
    erlang_bytecode(
        name = "topic_SUITE_beam_files",
        testonly = True,
        srcs = ["test/topic_SUITE.erl"],
        outs = ["test/topic_SUITE.beam"],
        hdrs = ["include/rabbit_stomp.hrl", "include/rabbit_stomp_frame.hrl", "include/rabbit_stomp_headers.hrl"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/amqp_client:erlang_app"],
    )
    erlang_bytecode(
        name = "util_SUITE_beam_files",
        testonly = True,
        srcs = ["test/util_SUITE.erl"],
        outs = ["test/util_SUITE.beam"],
        hdrs = ["include/rabbit_stomp_frame.hrl"],
        erlc_opts = "//:test_erlc_opts",
        deps = ["//deps/amqp_client:erlang_app"],
    )
