// Writes two EPUBs with the same text and different markup, for trying ink across editions on a device:
//   ink-fixture-ebook.epub       the ebook as published
//   ink-fixture-readalong.epub   sentences wrapped in <span id="chapter-one-sN">, as Storyteller builds the read-along edition
// Usage: node makeEpubs.mjs <output directory>     (or: scripts/inkfixtures <output directory>)
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ebookChapter, readAlongChapter } from "./chapters.mjs";

const container = `<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>`;

const opf = (title, id) => `<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">${id}</dc:identifier>
    <dc:title>${title}</dc:title>
    <dc:language>en</dc:language>
    <dc:creator>Ink Fixtures</dc:creator>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="chapter1"/></spine>
</package>`;

const nav = `<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head>
<body><nav epub:type="toc"><ol><li><a href="chapter1.xhtml">One: The Keeper Arrives</a></li></ol></nav></body>
</html>`;

const build = (outDir, file, title, id, chapter) => {
  const root = mkdtempSync(join(tmpdir(), "inkfixture-"));
  try {
    mkdirSync(join(root, "META-INF"));
    mkdirSync(join(root, "OEBPS"));
    writeFileSync(join(root, "mimetype"), "application/epub+zip");
    writeFileSync(join(root, "META-INF/container.xml"), container);
    writeFileSync(join(root, "OEBPS/content.opf"), opf(title, id));
    writeFileSync(join(root, "OEBPS/nav.xhtml"), nav);
    writeFileSync(join(root, "OEBPS/chapter1.xhtml"), chapter);
    const out = join(outDir, file);
    rmSync(out, { force: true });
    // The mimetype entry comes first and is stored uncompressed, as the EPUB spec requires.
    execFileSync("zip", ["-X", "-0", out, "mimetype"], { cwd: root, stdio: "ignore" });
    execFileSync("zip", ["-X", "-9", "-r", out, "META-INF", "OEBPS"], { cwd: root, stdio: "ignore" });
    return out;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
};

const outDir = process.argv[2];
if (!outDir) {
  console.error("usage: makeEpubs.mjs <output directory>");
  process.exit(1);
}
mkdirSync(outDir, { recursive: true });
console.log(build(outDir, "ink-fixture-ebook.epub", "Ink Fixture (ebook)", "urn:uuid:ink-fixture-ebook", ebookChapter()));
console.log(build(outDir, "ink-fixture-readalong.epub", "Ink Fixture (read-along markup)", "urn:uuid:ink-fixture-readalong", readAlongChapter()));
