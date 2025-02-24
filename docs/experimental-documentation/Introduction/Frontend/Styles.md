All styles are located under `src/styles` and are written in the 
[stylus CSS preprocessor language](https://stylus-lang.com/).

The root directory contains different themes for codetracer. When any of those themes is loaded,
it loads `codetracer.styl`, which includes styles for all the UI components.

Under the `components/` directory, you can find stylus files for each UI component/widget.

> [!CAUTION]
> Previously, the `components` directory did not exist. Instead, all CSS code was placed in the 
> `codetracer.styl` file, which was around 5.6K lines long at the time. 
> We did a refactor to separate it into several files, however due `codetracer.styl`'s massive size and
> complicated nature, there may be styles for components/widgets in unrelated files, or a lot of dead code.
> 
> Please move suspected dead code to a `legacy.styl` file(this may or may not exist, so create it if needed).
> After that, remove the code and do testing with your colleagues, which maintain the frontend.