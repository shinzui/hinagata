POST {{base_url}}/references/new
HTTP 201
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.id" == "4"

GET {{base_url}}/references
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$" count == 4
jsonpath "$[3].code" == "generated"
