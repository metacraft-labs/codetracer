// ruby?

// or rust?

// javacript?

let fs = require('node:fs');
let process = require('node:process');


const IGNORE_TYPES = {
    'LaunchRequestArguments': true,
}

class RustGenerator {
    constructor() {
        this.generatedDefinitions = [];
    }

    toLangFieldName(fieldName) {
        let rawFieldName = this.to_underscore_case(fieldName);
        if (rawFieldName === 'type') { // TODO: other keywords or rename with serde
            return 'r#type';
        } else {
            return rawFieldName;
        }
    }

    optionalType(internalType) {
        if (internalType === undefined) {
            return undefined;
        }
        return `Option<${internalType}>`;
    }

    to_underscore_case(name) {
        let parts = [];
        let lastTokenStart = 0;
        for (let i = 0; i < name.length; i += 1) {
            let symbol = name.charAt(i);
            // based on answers from here: https://stackoverflow.com/a/31415820
            // ТОDO: fix adapter_iD , aN_sI and similar
            if (symbol.toUpperCase() === symbol && symbol.toLowerCase() !== symbol) {
                if (lastTokenStart < i - 1) {
                    parts.push(name.charAt(lastTokenStart).toLowerCase() + name.slice(lastTokenStart + 1, i));
                    lastTokenStart = i;
                }
            }
        }
        if (lastTokenStart < name.length) {
            parts.push(name.charAt(lastTokenStart).toLowerCase() + name.slice(lastTokenStart + 1));
        }
        return parts.join('_');
    }
    
    toTypeName(name) {
        // console.log('type name : ', name);
        let tokens = name.split('_');
        let parts = [];
        for (let rawToken of tokens) {
            let token = String(rawToken);
            parts.push(token.charAt(0).toUpperCase());
            parts.push(token.slice(1));
        }
        // console.log('return ', parts.join(''));
        return parts.join('');
    }

    stringType() {
        return 'String';
    }

    loadType(property, required, propertyName, parentName) {
        console.log('loadType required: ', required, ' property: ', property);
        if (!required) {
            return this.optionalType(this.loadType(property, true, propertyName, parentName));
        } else if (typeof property === 'string') {
            return this.loadType({'type': property}, required, propertyName, parentName);
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
                    case 'string': return this.stringType();
                    case 'boolean': return 'bool';
                    case 'object' || 'enum': {
                        console.log(propertyName, property);
                        let typeName = this.toTypeName(`${parentName}_${propertyName}`);
                        if (this.translatesAsObjectMapping(property)) {
                            return this.generateMapping(property.additionalProperties.type);
                        } else {
                            this.visitTypes(typeName, property);
                        }
                        return typeName;
                    }
                    case 'array': {
                        let itemType = this.loadType(property.items, true, propertyName, parentName);
                        return `Vec<${itemType}>`;
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
            typeName !== 'ProtocolMessage' &&
            IGNORE_TYPES[typeName] === undefined;
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
        } else if (definition.type === 'string') {
            return this.generateAliasSource(typeName, this.stringType()); // eventually enums in some cases?
        }
        // TODO: allOf: combine fields?
        // or if special casing: composition?
    }

    generateFieldSource(fieldName, fieldType) {
        let annotation = '';
        if (fieldType.startsWith('Option<')) {
            annotation = '    #[serde(skip_serializing_if = "Option::is_none")]\n';
        }
        return `${annotation}    pub ${fieldName}: ${fieldType},`;
    }

    generateStructSource(typeName, fields) {
        let fieldSources = [];
        for (let field of fields) {
            fieldSources.push(this.generateFieldSource(field.name, field.type));
        }
        let fieldsText = fieldSources.join('\n');
        let derives = `#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]`;
        return `${derives}\npub struct ${typeName} {\n${fieldsText}\n}\n`;
    }

    generateMapping(valueDefinition) {
        let valueTypeSource = '';
        if (valueDefinition instanceof Array) {
            if (valueDefinition.length === 2 && valueDefinition[1] === "null") {
                console.log('in');
                valueTypeSource = this.optionalType(this.loadType(valueDefinition[0], true, '', ''));
            } else {
                console.log('WARNING: this value definition for a object/mapping not supported: ', valueDefinition, '; IGNORING');
                return undefined;
            }
        } else {
            valueTypeSource = this.loadType(valueDefinition, true, '', '');
        }
        return this.generateMappingSource(valueTypeSource);
    }

    generateMappingSource(valueTypeSource) {
        // for now assume key is String
        return `HashMap<String, ${valueTypeSource}>`;
    }

    generateAliasSource(typeName, otherType) {
        return `type ${typeName} = ${otherType};\n`;
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
                    fields.push({name: fieldName, type: fieldType});
                }
            }
        }

        if (this.typeGeneratedForCt(typeName)) {
            if (!this.translatesAsObjectMapping(definition)) {
                return this.generateStructSource(typeName, fields);
            } else {
                return this.generateMapping(definition.additionalProperties.type);
            }
        } else {
            return undefined;
        }
    }

    translatesAsObjectMapping(definition) {
        return definition.additionalProperties !== undefined && 
            definition.additionalProperties.type !== undefined;
    }

    generateEnum(typeName, definition) {
        // TODO
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
    // console.log(text);
    let sourceCode = `
// use num_derive::FromPrimitive;
use serde::{Deserialize, Serialize};
// use serde_repr::*;

use std::collections::HashMap;
// use crate::lang::*;
// use crate::value::{Type, Value};

${text}
`;
    fs.writeFileSync('src/db-backend/src/dap_types.rs', sourceCode);

}

run();

// TODO: 
// 1) maybe only produce code for arguments/payloads of requests/responses/events and for other types 
//   filtering out `XResponse`, `XEvent` leaving only their body, but keeping maybe `XRequest` fields for `XArgs`
// 2) fix/support more types
// 3) try to build actual rust types

// TODO: fix _
// integrate;
// schemars;
// nim?