let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/3522f4a51181d73c9c90fc27a7c0838bd29ae95f/package.dhall
        sha256:dcb19e2312e790bad14e622cc98a1281cd2298c5b564a2f0d0534d3c718d8803

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "hinagata"
      , namespace = "shinzui"
      , stableId = Some "project_01m3g16f9betfbxsaa5xc9knqn"
      , type = Schema.PackageType.Library
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Experimental
      , description = Some
          "Reproducible PostgreSQL test environments and fixtures for integration and end-to-end testing"
      , domains = [ "Testing", "PostgreSQL" ]
      }
    , repos =
      [ Schema.Repo::{ name = "hinagata", github = Some "shinzui/hinagata" } ]
    , packages =
      [ Schema.Package::{
        , name = "hinagata-core"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "hinagata-core"
        , description = Some "Pure fixture planning, validated identifiers, and connection descriptions"
        }
      , Schema.Package::{
        , name = "hinagata-postgres"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "hinagata-postgres"
        , description = Some "Atomic fixture loading over private PostgreSQL sessions"
        }
      , Schema.Package::{
        , name = "hinagata-cli"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "hinagata-cli"
        , description = Some "Fixture commands and scoped PostgreSQL lease handoff"
        }
      , Schema.Package::{
        , name = "hinagata-workbench-example"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "examples/workbench"
        , description = Some "Test-only HTTP workbench consumer"
        }
      , Schema.Package::{
        , name = "hinagata-keiro-example"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "examples/keiro-service"
        , description = Some "Test-only Keiro service and migration consumer"
        }
      ]
    }
