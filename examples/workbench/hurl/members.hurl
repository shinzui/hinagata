GET {{base_url}}/members
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$" count == 2
jsonpath "$[0].id" == 1
jsonpath "$[0].name" == "Ada"
jsonpath "$[1].name" == "Grace"

GET {{base_url}}/members/999
HTTP 404
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.error" == "member_not_found"
