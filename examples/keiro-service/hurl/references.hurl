GET {{base_url}}/references
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$" count == 3
jsonpath "$[0].code" == "alpha"
jsonpath "$[1].code" == "beta"
jsonpath "$[2].code" == "gamma"

GET {{base_url}}/references/missing
HTTP 404
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.error" == "reference_not_found"
