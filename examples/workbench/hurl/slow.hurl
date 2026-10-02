GET {{base_url}}/slow
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.ok" == true
