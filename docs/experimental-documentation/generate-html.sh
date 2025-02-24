#!/usr/bin/env bash
mkdir build &> /dev/null || (rm -rf build && mkdir build) || exit
cp ./*.md ./*.css ./*.js Advanced/ Introduction/ Misc/ build/ -r || exit
cd build || exit

title=$(grep "# " "$1" | head -1 | sed 's/[^ ]* //')
echo "</section><section id=\"sidebar\">" > _Sidebar.html || exit
pandoc --from=gfm --standalone --template ../sidebar_template.html -s _Sidebar.md >> _Sidebar.html || exit
echo "</section>" >> _Sidebar.html || exit
rm _Sidebar.md || exit

extract() {
  title=$(grep "# " "$1" | head -1 | sed 's/[^ ]* //')
  out_dir="$(echo "$(dirname "$1")"/"$(basename "$1" md)"html 2> /dev/null)"

  echo -e "\n\n" >> "$1"
  cat "_Sidebar.html" >> "$1"

  echo "Processing file: ${out_dir}"

	pandoc --from=gfm --standalone --template ../template.html -s "$1" -o "${out_dir}" --metadata=title:"${title}" 2> /dev/null

	sed -i 's/<table style="width:100%;">/<div class="table"><table style="width:100%;">/g' "${out_dir}"
  sed -i 's/<\/table>/<\/table><\/div>/g' "${out_dir}"

  rm "$(realpath "$1")" || exit
}

export -f extract

cpus=$(grep -c processor /proc/cpuinfo) || cpus=$(sysctl -n hw.ncpu)
find ./ -type f -name '*.md' -printf '%p\n' | parallel -j "${cpus}" extract || exit

mv _Home.html index.html || exit

if [ "$1" == 'localhost' ]; then
  find ./ -type f \( -iname \*.html -o -iname \*.js \) -exec sed -i 's/\.\//http:\/\/0.0.0.0:5000\//g' {} \;
  find ./ -type f \( -iname \*.html -o -iname \*.js \) -exec sed -i 's/https:\/\/dev-docs\.codetracer\.com\//http:\/\/0\.0\.0\.0:5000\//g' {} \;
  python3 -m http.server 5000
fi
