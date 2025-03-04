load(
    "@rules_erlang//:erlang_bytecode.bzl",
    "erlang_bytecode",
)
load(
    "@rules_erlang//:erlang_app.bzl",
    "DEFAULT_ERLC_OPTS",
    "DEFAULT_TEST_ERLC_OPTS",
    "erlang_app",
    "test_erlang_app",
)
load(
    "@rules_erlang//:ct.bzl",
    "assert_suites2",
    "ct_suite",
    "ct_suite_variant",
)
load("//:rabbitmq_home.bzl", "rabbitmq_home")
load("//:rabbitmq_run.bzl", "rabbitmq_run")

def without(item, elements):
    c = list(elements)
    c.remove(item)
    return c

STARTS_BACKGROUND_BROKER_TAG = "starts-background-broker"

MIXED_VERSION_CLUSTER_TAG = "mixed-version-cluster"

ENABLE_FEATURE_MAYBE_EXPR = "-enable-feature maybe_expr"

RABBITMQ_ERLC_OPTS = DEFAULT_ERLC_OPTS + [
    "-DINSTR_MOD=gm",
]

RABBITMQ_TEST_ERLC_OPTS = DEFAULT_TEST_ERLC_OPTS + [
    "+nowarn_export_all",
    "-DINSTR_MOD=gm",
]

RABBITMQ_DIALYZER_OPTS = [
    "-Werror_handling",
    "-Wunmatched_returns",
]

APP_VERSION = "3.12.0"

BROKER_VERSION_REQUIREMENTS_ANY = """
	{broker_version_requirements, []}
"""

ALL_PLUGINS = [
    "//deps/rabbit:erlang_app",
    "//deps/rabbitmq_amqp1_0:erlang_app",
    "//deps/rabbitmq_auth_backend_cache:erlang_app",
    "//deps/rabbitmq_auth_backend_http:erlang_app",
    "//deps/rabbitmq_auth_backend_ldap:erlang_app",
    "//deps/rabbitmq_auth_backend_oauth2:erlang_app",
    "//deps/rabbitmq_auth_mechanism_ssl:erlang_app",
    "//deps/rabbitmq_consistent_hash_exchange:erlang_app",
    "//deps/rabbitmq_event_exchange:erlang_app",
    "//deps/rabbitmq_federation:erlang_app",
    "//deps/rabbitmq_federation_management:erlang_app",
    "//deps/rabbitmq_jms_topic_exchange:erlang_app",
    "//deps/rabbitmq_management:erlang_app",
    "//deps/rabbitmq_mqtt:erlang_app",
    "//deps/rabbitmq_peer_discovery_aws:erlang_app",
    "//deps/rabbitmq_peer_discovery_consul:erlang_app",
    "//deps/rabbitmq_peer_discovery_etcd:erlang_app",
    "//deps/rabbitmq_peer_discovery_k8s:erlang_app",
    "//deps/rabbitmq_prometheus:erlang_app",
    "//deps/rabbitmq_random_exchange:erlang_app",
    "//deps/rabbitmq_recent_history_exchange:erlang_app",
    "//deps/rabbitmq_sharding:erlang_app",
    "//deps/rabbitmq_shovel:erlang_app",
    "//deps/rabbitmq_shovel_management:erlang_app",
    "//deps/rabbitmq_stomp:erlang_app",
    "//deps/rabbitmq_stream:erlang_app",
    "//deps/rabbitmq_stream_management:erlang_app",
    "//deps/rabbitmq_top:erlang_app",
    "//deps/rabbitmq_tracing:erlang_app",
    "//deps/rabbitmq_trust_store:erlang_app",
    "//deps/rabbitmq_web_dispatch:erlang_app",
    "//deps/rabbitmq_web_mqtt:erlang_app",
    "//deps/rabbitmq_web_stomp:erlang_app",
]

LABELS_WITH_TEST_VERSIONS = [
    "//deps/amqp10_common:erlang_app",
    "//deps/rabbit_common:erlang_app",
    "//deps/rabbit:erlang_app",
    "//deps/rabbit/apps/rabbitmq_prelaunch:erlang_app",
]

def all_plugins(rabbitmq_workspace = "@rabbitmq-server"):
    return [
        Label("{}{}".format(rabbitmq_workspace, p))
        for p in ALL_PLUGINS
    ]

def with_test_versions(deps):
    r = []
    for d in deps:
        if d in LABELS_WITH_TEST_VERSIONS:
            r.append(d.replace(":erlang_app", ":test_erlang_app"))
        else:
            r.append(d)
    return r

def rabbitmq_app(
        app_name = "",
        app_version = APP_VERSION,
        app_description = "",
        app_module = "",
        app_registered = [],
        app_env = "",
        app_extra_keys = "",
        extra_apps = [],
        extra_hdrs = [],
        extra_srcs = [],
        extra_priv = [],
        build_deps = [],
        deps = [],
        runtime_deps = []):
    erlang_app(
        app_name = app_name,
        app_version = app_version,
        app_description = app_description,
        app_module = app_module,
        app_registered = app_registered,
        app_env = app_env,
        app_extra_keys = app_extra_keys,
        extra_apps = extra_apps,
        extra_hdrs = extra_hdrs,
        extra_srcs = extra_srcs,
        extra_priv = extra_priv,
        erlc_opts = select({
            "@rules_erlang//:debug_build": without("-Werror", without("+deterministic", RABBITMQ_ERLC_OPTS)),
            "//conditions:default": RABBITMQ_ERLC_OPTS,
        }) + select({
            Label("//:test_build"): ["-DTEST=1", "+nowarn_export_all"],
            "//conditions:default": [],
        }),
        build_deps = build_deps,
        deps = deps,
        runtime_deps = runtime_deps,
    )

    test_erlang_app(
        app_name = app_name,
        app_version = app_version,
        app_description = app_description,
        app_module = app_module,
        app_registered = app_registered,
        app_env = app_env,
        app_extra_keys = app_extra_keys,
        extra_apps = extra_apps,
        extra_hdrs = extra_hdrs,
        extra_srcs = extra_srcs,
        extra_priv = extra_priv,
        erlc_opts = select({
            "@rules_erlang//:debug_build": without("+deterministic", RABBITMQ_TEST_ERLC_OPTS),
            "//conditions:default": RABBITMQ_TEST_ERLC_OPTS,
        }),
        build_deps = with_test_versions(build_deps),
        deps = with_test_versions(deps),
        runtime_deps = with_test_versions(runtime_deps),
    )

def rabbitmq_suite(erlc_opts = [], test_env = {}, **kwargs):
    ct_suite(
        erlc_opts = RABBITMQ_TEST_ERLC_OPTS + erlc_opts,
        ct_run_extra_args = [ENABLE_FEATURE_MAYBE_EXPR],
        test_env = dict({
            "RABBITMQ_CT_SKIP_AS_ERROR": "true",
            "LANG": "C.UTF-8",
        }.items() + test_env.items()),
        **kwargs
    )
    return kwargs["name"]

def broker_for_integration_suites(extra_plugins = []):
    rabbitmq_home(
        name = "broker-for-tests-home",
        plugins = [
            "//deps/rabbit:test_erlang_app",
            ":test_erlang_app",
        ] + extra_plugins,
        testonly = True,
    )

    rabbitmq_run(
        name = "rabbitmq-for-tests-run",
        home = ":broker-for-tests-home",
        testonly = True,
    )

def rabbitmq_test_helper(
        erlc_opts = RABBITMQ_TEST_ERLC_OPTS,
        **kwargs):
    erlang_bytecode(
        testonly = True,
        dest = "test",
        erlc_opts = erlc_opts,
        **kwargs
    )

def rabbitmq_integration_suite(
        name = None,
        tags = [],
        data = [],
        erlc_opts = [],
        additional_hdrs = [],
        additional_srcs = [],
        test_env = {},
        tools = [],
        deps = [],
        runtime_deps = [],
        **kwargs):
    package = native.package_name()

    extra_deps = [
        "//deps/rabbit_common:erlang_app",
        "//deps/rabbitmq_ct_helpers:erlang_app",
    ]
    if package != "deps/amqp_client":
        extra_deps.append("//deps/amqp_client:erlang_app")

    ct_suite(
        name = name,
        suite_name = name,
        tags = tags + [STARTS_BACKGROUND_BROKER_TAG],
        erlc_opts = select({
            "@rules_erlang//:debug_build": without("+deterministic", RABBITMQ_TEST_ERLC_OPTS + erlc_opts),
            "//conditions:default": RABBITMQ_TEST_ERLC_OPTS + erlc_opts,
        }),
        additional_hdrs = additional_hdrs,
        additional_srcs = additional_srcs,
        ct_run_extra_args = [ENABLE_FEATURE_MAYBE_EXPR],
        data = data,
        test_env = dict({
            "SKIP_MAKE_TEST_DIST": "true",
            "RABBITMQ_CT_SKIP_AS_ERROR": "true",
            "RABBITMQ_RUN": "$TEST_SRCDIR/$TEST_WORKSPACE/{}/rabbitmq-for-tests-run".format(package),
            "RABBITMQCTL": "$TEST_SRCDIR/$TEST_WORKSPACE/{}/broker-for-tests-home/sbin/rabbitmqctl".format(package),
            "RABBITMQ_PLUGINS": "$TEST_SRCDIR/$TEST_WORKSPACE/{}/broker-for-tests-home/sbin/rabbitmq-plugins".format(package),
            "RABBITMQ_QUEUES": "$TEST_SRCDIR/$TEST_WORKSPACE/{}/broker-for-tests-home/sbin/rabbitmq-queues".format(package),
            "LANG": "C.UTF-8",
        }.items() + test_env.items()),
        tools = [
            ":rabbitmq-for-tests-run",
        ] + tools,
        runtime_deps = [
            "//deps/rabbitmq_cli:elixir",
            "//deps/rabbitmq_cli:erlang_app",
            "//deps/rabbitmq_ct_client_helpers:erlang_app",
        ] + runtime_deps,
        deps = extra_deps + deps,
        **kwargs
    )

    ct_suite_variant(
        name = name + "-mixed",
        suite_name = name,
        tags = tags + [STARTS_BACKGROUND_BROKER_TAG, MIXED_VERSION_CLUSTER_TAG],
        ct_run_extra_args = [ENABLE_FEATURE_MAYBE_EXPR],
        data = data,
        test_env = dict({
            "SKIP_MAKE_TEST_DIST": "true",
            # The feature flags listed below are required. This means they must be enabled in mixed-version testing
            # before even starting the cluster because newer nodes don't have the corresponding compatibility/migration code.
            "RABBITMQ_FEATURE_FLAGS":
            # required starting from 3.11.0 in rabbit:
            "quorum_queue,implicit_default_bindings,virtual_host_metadata,maintenance_mode_status,user_limits," +
            # required starting from 3.12.0 in rabbit:
            "feature_flags_v2,stream_queue,classic_queue_type_delivery_support,classic_mirrored_queue_version," +
            "stream_single_active_consumer,direct_exchange_routing_v2,listener_records_in_ets,tracking_records_in_ets",
            # required starting from 3.12.0 in rabbitmq_management_agent:
            # empty_basic_get_metric, drop_unroutable_metric
            "RABBITMQ_RUN": "$TEST_SRCDIR/$TEST_WORKSPACE/{}/rabbitmq-for-tests-run".format(package),
            "RABBITMQCTL": "$TEST_SRCDIR/$TEST_WORKSPACE/{}/broker-for-tests-home/sbin/rabbitmqctl".format(package),
            "RABBITMQ_PLUGINS": "$TEST_SRCDIR/$TEST_WORKSPACE/{}/broker-for-tests-home/sbin/rabbitmq-plugins".format(package),
            "RABBITMQ_QUEUES": "$TEST_SRCDIR/$TEST_WORKSPACE/{}/broker-for-tests-home/sbin/rabbitmq-queues".format(package),
            "RABBITMQ_RUN_SECONDARY": "$(location @rabbitmq-server-generic-unix-3.11//:rabbitmq-run)",
            "LANG": "C.UTF-8",
        }.items() + test_env.items()),
        tools = [
            ":rabbitmq-for-tests-run",
            "@rabbitmq-server-generic-unix-3.11//:rabbitmq-run",
        ] + tools,
        runtime_deps = [
            "//deps/rabbitmq_cli:elixir",
            "//deps/rabbitmq_cli:erlang_app",
            "//deps/rabbitmq_ct_client_helpers:erlang_app",
        ] + runtime_deps,
        deps = extra_deps + deps,
        **kwargs
    )

    return name

def assert_suites(**kwargs):
    assert_suites2(**kwargs)
