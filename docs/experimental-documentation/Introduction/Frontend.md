The frontend code can be found under the `src/frontend` directory. It contains the following:

1. Minimal HTML and Javascript configuration
1. The frontend base, written in Nim using [karax](https://github.com/karaxnim/karax)
1. Tests under the `tests` directory
1. The main frontend services, under `services`
1. UI components, under `ui`

Due to bad folder ordering, parts of the frontend are located in different folders. For example:

1. Fonts are under `resources/fonts`
1. Styles are under `src/frontend/styles`