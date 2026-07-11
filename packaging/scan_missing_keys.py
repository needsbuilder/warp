#!/usr/bin/env python3
"""Warp 한글화: 코드가 참조하지만 로케일 파일에 없는 키를 찾아낸다.

사용: warp 저장소 루트에서 실행. 누락 키를 missing_keys.json으로 저장하고 개수를 출력.
종료 코드: 누락 0개면 0, 있으면 3.
"""
import glob
import json
import re
import sys

import yaml


def decode_rust(s: str) -> str:
    s = re.sub(r"\\u\{([0-9a-fA-F]+)\}", lambda m: chr(int(m.group(1), 16)), s)
    return (
        s.replace('\\"', '"').replace("\\'", "'").replace("\\n", "\n")
        .replace("\\t", "\t").replace("\\\\", "\\")
    )


def flat(d, p=""):
    o = {}
    for k, v in d.items():
        kk = f"{p}.{k}" if p else str(k)
        o.update(flat(v, kk) if isinstance(v, dict) else {kk: v})
    return o


def main() -> int:
    pairs = {}
    for f in glob.glob("app/src/**/*.rs", recursive=True) + glob.glob(
        "crates/**/*.rs", recursive=True
    ):
        src = open(f, encoding="utf-8", errors="ignore").read()
        for m in re.finditer(
            r'menu_label\(\s*"([^"]+)"\s*,\s*"((?:[^"\\]|\\.)*)"', src
        ):
            pairs.setdefault(m.group(1), decode_rust(m.group(2)))

    have = set(flat(yaml.safe_load(open("resources/bundled/locales/en.yml"))["en"]))
    extra = yaml.safe_load(open("resources/bundled/locales/extra.yml"))
    have |= set(extra["en"])
    # ko 누락도 검사 (extra.yml en/ko 불균형 방지)
    ko_missing_in_extra = set(extra["en"]) - set(extra["ko"])

    missing = {
        k: v
        for k, v in sorted(pairs.items())
        if k not in have and not k.startswith(("test.", "definitely."))
    }
    json.dump(missing, open("missing_keys.json", "w"), ensure_ascii=False, indent=1)
    print(f"코드 참조 키 {len(pairs)}개 / 누락 {len(missing)}개 → missing_keys.json")
    if ko_missing_in_extra:
        print(f"⚠️ extra.yml에서 ko 번역 누락: {len(ko_missing_in_extra)}개")
    return 3 if (missing or ko_missing_in_extra) else 0


if __name__ == "__main__":
    sys.exit(main())
