GET {{base_url}}/hold
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.ok" == true
