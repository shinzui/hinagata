GET {{base_url}}/health
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.ok" == true
jsonpath "$.role" == "hinagata_example_app"
