// ruby?

// or rust?

// javacript?

let fs = require('fs');

function to_underscore_case(name) {
    // TODO;
    return name;
}

class RustGenerator {
    constructor() {
        this.generatedDefinitions = [];
    }

    loadType(property) {
        console.log('loadType ', property);
        if (property.type === undefined) {
            let ref = property['$ref'];
            if (ref !== undefined && ref.startsWith('#/definitions/')) {
                return ref.slice('#/definitions/'.length);
            } else {
                return '<unknown>';
            }
        }
        if (typeof property.type === 'string') {
            switch (property.type) {
                case 'integer': return 'i64';
                case 'string': return 'String';
                case 'boolean': return 'bool';
                default: return property.type;
            }
        } else {
            return 'serde::Value'; // serde::Value : acting as a dynamic-like JSON any value
        }
    }

    generateType(typeName, definition) {
        if (definition.type === 'object') {
            return this.generateObject(typeName, definition);
        }
        else if (definition.allOf && definition.allOf.length == 2) {
            // assume Request, Response or Event: generate for the second type
            let secondDefinition = definition.allOf[1];
            console.log('secondDefinition', secondDefinition);
            return this.generateObject(typeName, secondDefinition);
        }
        // TODO: allOf: combine fields?
        // or if special casing: composition?
    }

    generateObject(typeName, definition) {
        let fields = [];
        if (definition.properties !== undefined) {
            for (let [name, property] of Object.entries(definition.properties)) {
                let fieldType = this.loadType(property);
                let fieldName = to_underscore_case(name);
                fields.push(`    pub ${fieldName}: ${fieldType},`);
            }
        }
        let fieldsText = fields.join('\n');
        let derives = `#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]`;
        return `${derives}\npub struct ${typeName} {\n${fieldsText}\n}\n`;
    }

    registerType(typeName, definition) {
        let generatedType = this.generateType(typeName, definition);
        if (generatedType !== undefined) {
            this.generatedDefinitions.push(generatedType);
        }
    }

    toText() {
        return this.generatedDefinitions.join('\n');
    }
}

function run() {
    let schema = fs.readFileSync("debugAdapterProtocol.json", {encoding: 'utf8'});
    let definitions = JSON.parse(schema).definitions;
    // console.log(definitions);
    let generator = new RustGenerator();
    var i = 0;
    for ( let [typeName, definition] of Object.entries(definitions)) {
        console.log('--------------------');
        console.log(typeName);
        console.log(definition);
        if (definition.allOf !== undefined) {
            console.log(definition.allOf[1].properties);
        }

        generator.registerType(typeName, definition, 'rust');
        // if (i >= 10) {
        //     break;
        // }
        i += 1;
    }
    let text = generator.toText();
    console.log(text);

}

run();
