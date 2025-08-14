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

    loadType(property, required, propertyName, parentName) {
        // console.log('loadType ', property);
        if (!required) {
            let internalType = this.loadType(property, true, propertyName, parentName);
            return `Option<${internalType}>`;
        } else {
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
                    case 'object': {
                        let typeName = `${parentName}${propertyName}`;
                        this.registerType(`${parentName}${propertyName}`, property);
                        return typeName;
                    }
                    default: return property.type;
                }
            } else {
                return 'serde::Value'; // serde::Value : acting as a dynamic-like JSON any value
            }
        }
    }

    generateType(typeName, definition) {
        if (definition.type === 'object') {
            return this.generateObject(typeName, definition);
        }
        else if (definition.allOf && definition.allOf.length == 2) {
            // assume Request, Response or Event: generate for the second type
            let secondDefinition = definition.allOf[1];
            // console.log('secondDefinition', secondDefinition);
            return this.generateObject(typeName, secondDefinition);
        }
        // TODO: allOf: combine fields?
        // or if special casing: composition?
    }

    generateObject(typeName, definition) {
        let fields = [];
        console.log('generateObject:\n----------');
        console.log('properties: ', definition.properties);
        console.log('required: ', definition.required);
        if (definition.properties !== undefined) {
            for (let [name, property] of Object.entries(definition.properties)) {
                let required = definition.required !== undefined && definition.required.includes(name);
                let fieldType = this.loadType(property, required, name, typeName);
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
        if (i === 57) {
            console.log('--------------------');
            console.log('type: ', typeName);
            console.log('==');
            console.log('definition: ', definition);

            generator.registerType(typeName, definition, 'rust');
        }
        i += 1;
    }
    let text = generator.toText();
    console.log(text);

}

run();

// TODO: 
// 1) maybe only produce code for arguments/payloads of requests/responses/events and for other types 
//   filtering out `XResponse`, `XEvent` leaving only their body, but keeping maybe `XRequest` fields for `XArgs`
// 2) fix/support more types
// 3) try to build actual rust types
