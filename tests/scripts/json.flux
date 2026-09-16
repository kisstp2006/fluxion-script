const json = @import("json");

const text = "{\"name\": \"Ada\", \"level\": 3, \"tags\": [\"a\", \"b\"], \"pos\": {\"x\": 1.5}}";
const data = try json.parse(text);
print(data["name"], data["level"], data["tags"][1], data["pos"]["x"]);
// out: Ada 3 b 1.5
print(json.stringify({"ok": true, "list": [1, 2.5, null], "s": "q\"uote"}));
// out: {"ok":true,"list":[1,2.5,null],"s":"q\"uote"}
struct Save {
    var level: int = 1;
    var name: string = "x";
    var pos = vec2(1, 2);
}
print(json.stringify(Save{}));
// out: {"level":1,"name":"x","pos":[1.0,2.0]}
const bad = json.parse("{\"a\": }") catch |e| e.message.?;
print(bad.lines()[0]);
// out: line 1, column 7: expected a value after ':', found '}'
