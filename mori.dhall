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
    }
