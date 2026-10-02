let Schema = https://raw.githubusercontent.com/shinzui/hurl-workbench/a29d26ad5e90aa762de88be18f06fddf67b6d02f/schema/package.dhall

in  Schema.Workspace::{
    , schemaVersion = Schema.schemaVersion
    , parameters =
      [ Schema.Parameter::{ name = "base_url", defaultValue = Some "http://127.0.0.1:18080" }
      , Schema.Parameter::{ name = "service_port", defaultValue = Some "18080" }
      ]
    , fragments =
      [ Schema.Fragment::{ name = "health", path = "hurl/health.hurl" }
      , Schema.Fragment::{ name = "members", path = "hurl/members.hurl" }
      , Schema.Fragment::{ name = "intentional-failure", path = "hurl/intentional-failure.hurl" }
      , Schema.Fragment::{ name = "slow", path = "hurl/slow.hurl" }
      ]
    , workflows =
      [ Schema.Workflow::{ name = "health", fragments = [ "health" ], parameters = [ "base_url" ] }
      , Schema.Workflow::{ name = "members", fragments = [ "members" ], parameters = [ "base_url" ] }
      , Schema.Workflow::{ name = "intentional-failure", fragments = [ "intentional-failure" ], parameters = [ "base_url" ] }
      , Schema.Workflow::{ name = "slow", fragments = [ "slow" ], parameters = [ "base_url" ] }
      ]
    , recipes =
      [ Schema.Recipe::{ name = "health", workflow = "health", safety = Schema.Safety.ReadOnly }
      , Schema.Recipe::{ name = "members", workflow = "members", safety = Schema.Safety.ReadOnly }
      , Schema.Recipe::{ name = "intentional-failure", workflow = "intentional-failure", safety = Schema.Safety.ReadOnly }
      , Schema.Recipe::{ name = "slow", workflow = "slow", safety = Schema.Safety.ReadOnly }
      ]
    , services =
      [ Schema.Service::{
        , name = "member-service"
        , command = Schema.CommandSpec::{
          , executable = "./service-wrapper.sh"
          , environment = [ Schema.EnvironmentBinding::{ variable = "PORT", parameter = "service_port" } ]
          }
        , readiness = Schema.Readiness.Http Schema.HttpReadiness::{ url = "http://127.0.0.1:{{service_port}}/health" }
        }
      ]
    , suites =
      [ Schema.Suite::{
        , name = "default"
        , runs = [ Schema.RunReference.Recipe "health", Schema.RunReference.Recipe "members" ]
        , service = Some "member-service"
        , failFast = True
        }
      , Schema.Suite::{
        , name = "intentional-failure"
        , runs = [ Schema.RunReference.Recipe "intentional-failure" ]
        , service = Some "member-service"
        , failFast = True
        }
      , Schema.Suite::{
        , name = "cancellation"
        , runs = [ Schema.RunReference.Recipe "slow" ]
        , service = Some "member-service"
        , failFast = True
        }
      ]
    }
