const body = document.body;
const content = document.getElementById("tm_webpreview_content");
const header = document.getElementById("tm_webpreview_header");
const selector = header?.querySelector("#theme_selector");
if (body?.id !== "tm_webpreview_body" || !content || !selector)
	return;

const options = Array.from(selector.options);
const stylesheets = Array.from(document.querySelectorAll('link[rel="stylesheet"][media="screen"]'));
for (const name of dark ? ["dark", "night"] : ["plain", "bright"]) {
	const option = options.find(option => option.value === name);
	if (!option)
		continue;

	const stylesheet = stylesheets.find(link => {
		const url = new URL(link.href);
		return (url.protocol === "tm-file:" || url.protocol === "file:") &&
			decodeURIComponent(url.pathname) === `${option.title}/style.css`;
	});
	if (!stylesheet)
		continue;

	body.className = content.className = selector.value = name;
	for (const [id, filename] of [["gradient", "header"], ["teaser", "teaser"]]) {
		const image = header.querySelector(`#${id}`);
		if (image)
			image.src = new URL(`images/${filename}.png`, stylesheet.href).href;
	}
	const switcher = header.querySelector("#theme_switcher");
	if (switcher)
		switcher.style.display = "none";
	break;
}
