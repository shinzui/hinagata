GET {{base_url}}/members
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$[0].name" == "Not Ada"
