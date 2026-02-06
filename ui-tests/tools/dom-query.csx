#!/usr/bin/env dotnet-script
// Usage: dotnet script dom-query.csx <html-file> <css-selector> [--count] [--attrs] [--text]
// Example: dotnet script dom-query.csx snapshot.html "div[id*=eventLog]" --count
// Example: dotnet script dom-query.csx snapshot.html "textarea" --attrs

#r "nuget: AngleSharp, 1.1.0"

using AngleSharp;
using AngleSharp.Dom;
using AngleSharp.Html.Parser;

if (Args.Count < 2)
{
    Console.WriteLine("Usage: dotnet script dom-query.csx <html-file> <css-selector> [options]");
    Console.WriteLine("Options:");
    Console.WriteLine("  --count    Only show count of matching elements");
    Console.WriteLine("  --attrs    Show all attributes of matching elements");
    Console.WriteLine("  --text     Show text content of matching elements");
    Console.WriteLine("  --outer    Show outer HTML (truncated)");
    Console.WriteLine("  --parents  Show parent chain for each match");
    Console.WriteLine();
    Console.WriteLine("Examples:");
    Console.WriteLine("  dotnet script dom-query.csx snapshot.html \"div[id*=eventLog]\" --count");
    Console.WriteLine("  dotnet script dom-query.csx snapshot.html \"textarea\" --attrs");
    Console.WriteLine("  dotnet script dom-query.csx snapshot.html \".monaco-editor\" --parents");
    return 1;
}

var htmlFile = Args[0];
var selector = Args[1];
var showCount = Args.Contains("--count");
var showAttrs = Args.Contains("--attrs");
var showText = Args.Contains("--text");
var showOuter = Args.Contains("--outer");
var showParents = Args.Contains("--parents");

if (!File.Exists(htmlFile))
{
    Console.Error.WriteLine($"File not found: {htmlFile}");
    return 1;
}

var config = Configuration.Default;
var context = BrowsingContext.New(config);
var parser = context.GetService<IHtmlParser>()!;

Console.Error.WriteLine($"Loading {htmlFile}...");
var html = await File.ReadAllTextAsync(htmlFile);
Console.Error.WriteLine($"Parsing {html.Length:N0} bytes...");
var document = await parser.ParseDocumentAsync(html);

Console.Error.WriteLine($"Querying: {selector}");
var matches = document.QuerySelectorAll(selector);

Console.WriteLine($"Found {matches.Length} match(es) for selector: {selector}");
Console.WriteLine();

if (showCount)
{
    return 0;
}

int index = 0;
foreach (var el in matches)
{
    index++;
    Console.WriteLine($"--- Match {index} ---");
    Console.WriteLine($"Tag: <{el.TagName.ToLower()}>");

    if (el.Id != null)
        Console.WriteLine($"ID: {el.Id}");

    if (!string.IsNullOrEmpty(el.ClassName))
        Console.WriteLine($"Class: {el.ClassName}");

    if (showAttrs)
    {
        Console.WriteLine("Attributes:");
        foreach (var attr in el.Attributes)
        {
            var value = attr.Value.Length > 100 ? attr.Value.Substring(0, 100) + "..." : attr.Value;
            Console.WriteLine($"  {attr.Name}=\"{value}\"");
        }
    }

    if (showText)
    {
        var text = el.TextContent?.Trim() ?? "";
        if (text.Length > 200) text = text.Substring(0, 200) + "...";
        Console.WriteLine($"Text: {text}");
    }

    if (showOuter)
    {
        var outer = el.OuterHtml;
        if (outer.Length > 500) outer = outer.Substring(0, 500) + "...";
        Console.WriteLine($"HTML: {outer}");
    }

    if (showParents)
    {
        Console.WriteLine("Parent chain:");
        var parent = el.ParentElement;
        int depth = 1;
        while (parent != null && depth <= 10)
        {
            var id = parent.Id != null ? $" id=\"{parent.Id}\"" : "";
            var cls = !string.IsNullOrEmpty(parent.ClassName)
                ? $" class=\"{(parent.ClassName.Length > 50 ? parent.ClassName.Substring(0, 50) + "..." : parent.ClassName)}\""
                : "";
            Console.WriteLine($"  {new string(' ', depth * 2)}<{parent.TagName.ToLower()}{id}{cls}>");
            parent = parent.ParentElement;
            depth++;
        }
    }

    Console.WriteLine();
}

return 0;
