// ruby?

// or rust?

// javacript?

let fs = require('node:fs');
let process = require('node:process');

function to_underscore_case(name) {
    // TODO;
    return name;
}

class RustGenerator {
    constructor() {
        this.generatedDefinitions = [];
    }

    toLangFieldName(fieldName) {
        let rawFieldName = to_underscore_case(fieldName);
        if (rawFieldName === 'type') { // TODO: other keywords or rename with serde
            return 'r#type';
        } else {
            return rawFieldName;
        }
    }

    loadType(property, required, propertyName, parentName) {
        // console.log('loadType ', property);
        if (!required) {
            let internalType = this.loadType(property, true, propertyName, parentName);
            if (internalType === undefined) {
                return undefined;
            }
            return `Option<${internalType}>`;
        } else {
            if (property.type === undefined) {
                let ref = property['$ref'];
                if (ref !== undefined && ref.startsWith('#/definitions/')) {
                    return ref.slice('#/definitions/'.length);
                } else {
                    console.log(`WARNING: UNKNOWN DEFINITION: ${ref}`);
                    // process.exit(1);
                    return undefined;
                }
            }
            if (typeof property.type === 'string') {
                switch (property.type) {
                    case 'integer': return 'i64';
                    case 'number': return 'i64'; // TODO: float? other?
                    case 'string': return 'String';
                    case 'boolean': return 'bool';
                    case 'object' | 'enum': {
                        let typeName = `${parentName}${propertyName}`;
                        this.visitTypes(`${parentName}${propertyName}`, property);
                        return typeName;
                    }
                    default: return property.type;
                }
            } else {
                return 'serde_json::Value'; // serde_json::Value : acting as a dynamic-like JSON any value
            }
        }
    }

    typeGeneratedForCt(typeName) {
        return !typeName.endsWith('Request') &&
            !typeName.endsWith('Response') && 
            !typeName.endsWith('Event') &&
            typeName !== 'ProtocolMessage';
    }
    
    generateType(typeName, definition) {
        if (definition.type === 'object') {
            return this.generateObject(typeName, definition);
        } else if (definition.type === 'enum') {
            return this.generateEnum(typeName, definition);
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
        console.log('generateObject: ', typeName, '\n----------');
        console.log('properties: ', definition.properties);
        console.log('required: ', definition.required);
        if (definition.properties !== undefined) {
            for (let [name, property] of Object.entries(definition.properties)) {
                let required = definition.required !== undefined && definition.required.includes(name);
                let fieldType = this.loadType(property, required, name, typeName);
                if (fieldType !== undefined) {
                    let fieldName = this.toLangFieldName(name);
                    fields.push(`    pub ${fieldName}: ${fieldType},`);
                }
            }
        }
        if (this.typeGeneratedForCt(typeName)) {
            let fieldsText = fields.join('\n');
            let derives = `#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]`;
            return `${derives}\npub struct ${typeName} {\n${fieldsText}\n}\n`;
        } else {
            return undefined;
        }
    }

    visitTypes(typeName, definition) {
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
    let generator = new RustGenerator();
    var i = 0;
    for ( let [typeName, definition] of Object.entries(definitions)) {
        // if (i < 57) {
            console.log('--------------------');
            console.log('type: ', typeName);
            console.log('==');
            console.log('definition: ', definition);

            generator.visitTypes(typeName, definition, 'rust');
        // }
        i += 1;
    }
    let text = generator.toText();
    console.log(text);
    let sourceCode = `
use num_derive::FromPrimitive;
use serde::{Deserialize, Serialize};
use serde_repr::*;

// use std::collections::HashMap;
// use crate::lang::*;
// use crate::value::{Type, Value};

${text}
`;
    fs.writeFileSync('src/db-backend/src/types.rs', sourceCode);

}

run();

// TODO: 
// 1) maybe only produce code for arguments/payloads of requests/responses/events and for other types 
//   filtering out `XResponse`, `XEvent` leaving only their body, but keeping maybe `XRequest` fields for `XArgs`
// 2) fix/support more types
// 3) try to build actual rust types
