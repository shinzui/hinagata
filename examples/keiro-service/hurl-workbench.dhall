let Schema = https://raw.githubusercontent.com/shinzui/hurl-workbench/a29d26ad5e90aa762de88be18f06fddf67b6d02f/schema/package.dhall

in  Schema.Workspace::{
    , schemaVersion = Schema.schemaVersion
    , parameters =
      [ Schema.Parameter::{ name = "base_url", defaultValue = Some "http://127.0.0.1:18081" }
      , Schema.Parameter::{ name = "service_port", defaultValue = Some "18081" }
      ]
    , fragments =
      [ Schema.Fragment::{ name = "health", path = "hurl/health.hurl" }
      , Schema.Fragment::{ name = "references", path = "hurl/references.hurl" }
      , Schema.Fragment::{ name = "references-alternate", path = "hurl/references-alternate.hurl" }
      , Schema.Fragment::{ name = "counter-write", path = "hurl/counter-write.hurl" }
      , Schema.Fragment::{ name = "generated-id", path = "hurl/generated-id.hurl" }
      , Schema.Fragment::{ name = "hold", path = "hurl/hold.hurl" }
      ]
    , workflows =
      [ Schema.Workflow::{ name = "health", fragments = [ "health" ], parameters = [ "base_url" ] }
      , Schema.Workflow::{ name = "references", fragments = [ "references" ], parameters = [ "base_url" ] }
      , Schema.Workflow::{ name = "references-alternate", fragments = [ "references-alternate" ], parameters = [ "base_url" ] }
      , Schema.Workflow::{ name = "counter-write", fragments = [ "counter-write" ], parameters = [ "base_url" ] }
      , Schema.Workflow::{ name = "generated-id", fragments = [ "generated-id" ], parameters = [ "base_url" ] }
      , Schema.Workflow::{ name = "hold", fragments = [ "hold" ], parameters = [ "base_url" ] }
      ]
    , recipes =
      [ Schema.Recipe::{ name = "health", workflow = "health", safety = Schema.Safety.ReadOnly }
      , Schema.Recipe::{ name = "references", workflow = "references", safety = Schema.Safety.ReadOnly }
      , Schema.Recipe::{ name = "references-alternate", workflow = "references-alternate", safety = Schema.Safety.ReadOnly }
      , Schema.Recipe::{ name = "counter-write", workflow = "counter-write", safety = Schema.Safety.Mutating }
      , Schema.Recipe::{ name = "generated-id", workflow = "generated-id", safety = Schema.Safety.Mutating }
      , Schema.Recipe::{ name = "hold", workflow = "hold", safety = Schema.Safety.ReadOnly }
      ]
    , services =
      [ Schema.Service::{
        , name = "keiro-service"
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
        , runs = [ Schema.RunReference.Recipe "health", Schema.RunReference.Recipe "references" ]
        , service = Some "keiro-service"
        , failFast = True
        }
      , Schema.Suite::{
        , name = "alternate"
        , runs = [ Schema.RunReference.Recipe "health", Schema.RunReference.Recipe "references-alternate" ]
        , service = Some "keiro-service"
        , failFast = True
        }
      , Schema.Suite::{
        , name = "counter-write"
        , runs = [ Schema.RunReference.Recipe "counter-write" ]
        , service = Some "keiro-service"
        , failFast = True
        }
      , Schema.Suite::{
        , name = "generated-id"
        , runs = [ Schema.RunReference.Recipe "generated-id" ]
        , service = Some "keiro-service"
        , failFast = True
        }
      , Schema.Suite::{
        , name = "cancellation"
        , runs = [ Schema.RunReference.Recipe "hold" ]
        , service = Some "keiro-service"
        , failFast = True
        }
      ]
    }
