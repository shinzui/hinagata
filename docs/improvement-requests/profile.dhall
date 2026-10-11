--| Cross-repository improvement requests with stable IR-N handles.
-- Requires okf 0.9.0.0 or later.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.20.0/package.dhall
        sha256:079a5b3679dccafd2070535b3d59a0ffdf28e20bf9cacfe095dca96c8012879a

in  Profiles.coordination.improvementRequests
