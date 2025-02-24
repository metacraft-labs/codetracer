'use strict'

/**
 * Troll jQuery users
 * @param x - ID of the element to request
 * @returns {HTMLElement|null} Element returned or null
 */
function $(x)
{
    return document.getElementById(x);
}

/**
 * Helper to quickly create an element
 * @param { string } tag - HTML element tag type
 * @param { string } content - Text content of the element
 * @param { string } id - ID of the element
 * @param { string } className - Class name of the element
 * @param { Array<Array<string>>|null } additionalInfo - Additional key-value pairs to add to the element
 * @param { HTMLElement } parent - Parent element to attach to
 * @return { HTMLElement } The element in question
 */
function createElement(tag, content, id, className, additionalInfo, parent)
{
    let element = document.createElement(tag);
    element.textContent = content;
    element.id = id;
    element.className = className;

    if (additionalInfo !== null)
        for (let info in additionalInfo)
            element[additionalInfo[info][0]] = additionalInfo[info][1];

    parent.appendChild(element);

    return element;
}

function main()
{

}

main()