/// Test fixtures shared by the Config Lab tests.
library;

/// Fixture shaped like the sample game's saves/save.schema.json (see
/// docs/SAMPLES.md): nested object, array of objects, enum, integer bounds,
/// string pattern.
const saveSchema = '''
{
  "\$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Neon Dungeon save",
  "type": "object",
  "required": ["version", "player", "inventory"],
  "additionalProperties": false,
  "properties": {
    "version": {"type": "integer", "minimum": 1, "maximum": 3},
    "slotName": {"type": "string", "maxLength": 12, "pattern": "^[A-Za-z0-9 _-]+\$", "default": "Slot"},
    "player": {
      "type": "object",
      "title": "Player",
      "required": ["name", "class", "level", "hp"],
      "properties": {
        "name": {"type": "string", "minLength": 1, "maxLength": 16},
        "class": {"type": "string", "enum": ["rogue", "mage", "knight"]},
        "level": {"type": "integer", "minimum": 1, "maximum": 99},
        "hp": {"type": "number", "minimum": 0},
        "hardcore": {"type": "boolean", "default": false}
      }
    },
    "inventory": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "count"],
        "properties": {
          "id": {"type": "string", "pattern": "^[a-z_]+\$"},
          "count": {"type": "integer", "minimum": 1, "maximum": 99}
        }
      }
    }
  }
}
''';

const validSave = '''
{
  "version": 2,
  "slotName": "Main run",
  "player": {"name": "Kaya", "class": "rogue", "level": 7, "hp": 42.5, "hardcore": false},
  "inventory": [{"id": "potion", "count": 3}, {"id": "iron_key", "count": 1}]
}
''';
