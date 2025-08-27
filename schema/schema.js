// ruby?

// or rust?

// javacript?

let fs = require('node:fs');
let process = require('node:process');


const IGNORE_TYPES = {
    'LaunchRequestArguments': true,
}

class Generator {
    constructor() {
        this.generatedDefinitions = [];
    }

    to_underscore_case(original) {
        let parts = [];
        let lastTokenStart = 0;
        let isLastSymbolUpper = false;
        let customChange = false;
        for (let i = 0; i < original.length; i += 1) {
            let symbol = original.charAt(i);
            // based on answers from here: https://stackoverflow.com/a/31415820
            // ТОDO: fix adapter_iD , aN_sI and similar
            if (symbol.toUpperCase() === symbol && symbol.toLowerCase() !== symbol) {
                if (!isLastSymbolUpper) { // if the last symbol is also upper, don't start a new token: e.g. keep ANSI one token
                    if (lastTokenStart < i - 1) {
                        parts.push(original.charAt(lastTokenStart).toLowerCase() + original.slice(lastTokenStart + 1, i).toLowerCase());
                        lastTokenStart = i;
                    }
                } else {
                    customChange = true; 
                    // multiple capital letters => hard to turn back to camel case, 
                    // signify so generator can hint keeping the original field for serialization
                }
                isLastSymbolUpper = true;
            } else {
                isLastSymbolUpper = false;
            }
        }
        if (lastTokenStart < original.length) {
            parts.push(original.charAt(lastTokenStart).toLowerCase() + original.slice(lastTokenStart + 1).toLowerCase());
        }
        return [parts.join('_'), customChange];
    }
    
    toPascalCase(original) {
        // console.log('type name : ', name);
        let tokens = original.split('_');
        let parts = [];
        for (let rawToken of tokens) {
            let token = String(rawToken);
            parts.push(token.charAt(0).toUpperCase());
            parts.push(token.slice(1));
        }
        // console.log('return ', parts.join(''));
        return parts.join('');
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
                    case 'integer': return this.intType();
                    case 'number': return this.numberType(); // TODO: float? other?
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
                        return this.arrayType(itemType);
                    }
                    default: return property.type;
                }
            } else if (property.type instanceof Array && property.type.length === 2 && property.type[1] === 'null') {
                return this.optionalType(this.loadType(property.type[0], true, '', ''));
            } else {
                return this.jsonValueType();
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
        else if (definition.allOf && definition.allOf.length === 2) {
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
                    let {fieldName, customChange} = this.toLangFieldName(name);
                    fields.push({name: fieldName, type: fieldType, original: name, customChange: customChange});
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

    toSourceCode() {
        let headers = this.headers();
        let definitions = this.generatedDefinitions.join('\n');
        let sourceCode = `${headers}\n${definitions}\n`;
        return sourceCode;
    }
}

class RustGenerator extends Generator {
    toTypeName(original) {
        return this.toPascalCase(original);
    }

    toLangFieldName(fieldName) {
        let [rawFieldName, customChange] = this.to_underscore_case(fieldName);
        if (rawFieldName === 'type') { // TODO: other keywords or rename with serde
            return {
                fieldName: 'r#type',
                customChange: true
            };
        } else {
            return {
                fieldName: rawFieldName,
                customChange: customChange
            }; 
        }
    }

    generateMappingSource(valueTypeSource) {
        // for now assume key is String
        return `HashMap<String, ${valueTypeSource}>`;
    }

    generateAliasSource(typeName, otherType) {
        return `type ${typeName} = ${otherType};\n`;
    }

    optionalType(internalType) {
        if (internalType === undefined) {
            return undefined;
        }
        return `Option<${internalType}>`;
    }

    stringType() {
        return 'String';
    }

    intType() {
        return 'i64';
    }

    numberType() {
        return 'i64';
    }

    arrayType(itemType) {
        return `Vec<${itemType}>`;
    }

    jsonValueType() {
        return 'serde_json::Value'; // serde_json::Value : acting as a dynamic-like JSON any value
    }

    generateFieldSource(field) {
        let annotations = '';
        if (field.type.startsWith('Option<')) {
            annotations = '    #[serde(skip_serializing_if = "Option::is_none")]\n';
        }
        if (field.customChange) {
            // r#type, a_ansistyle => aANSIStyle; instead of aAnsistyle;
            annotations += `    #[serde(rename = "${field.original}")]\n`;
        }
        return `${annotations}    pub ${field.name}: ${field.type},`;
    }

    generateStructSource(typeName, fields) {
        let fieldSources = [];
        for (let field of fields) {
            fieldSources.push(this.generateFieldSource(field));
        }
        let fieldsText = fieldSources.join('\n');
        let derives = `#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]`;
        return `${derives}\npub struct ${typeName} {\n${fieldsText}\n}\n`;
    }

    headers() {
        // if needed for enums, others..
        // use num_derive::FromPrimitive;
        // use serde_repr::*;
        return `
// THIS IS AUTO-GENERATED, DON'T CHANGE MANUALLY
// currently generated by .. TODO

use serde::{Deserialize, Serialize};

use std::collections::HashMap;
`;

    }

}


class NimGenerator extends Generator {

}

function run() {
    // "debugAdapterProtocol.json"
    // src/db-backend/ct_types.json
    let schema = fs.readFileSync("debugAdapterProtocol.json", {encoding: 'utf8'});
    let targetLang = 'rust';
    let definitions = JSON.parse(schema).definitions;
    let generator = targetLang === 'rust' ? new RustGenerator() : new NimGenerator();
    var i = 0;
    for ( let [typeName, definition] of Object.entries(definitions)) {
        console.log('--------------------');
        console.log('type: ', typeName);
        console.log('==');
        console.log('definition: ', definition);

        generator.visitTypes(typeName, definition, 'rust');

        i += 1;
    }
    let sourceCode = generator.toSourceCode();

    fs.writeFileSync('src/db-backend/src/dap_types.rs', sourceCode);

}

run();

// TODO: 
// schemars;
// nim?