import re
import subprocess

def parse_bybylang(src: str) -> str:
    lines = src.strip().splitlines()
    java_code = []
    functions = {}
    current_func = None
    func_indent = 0

    for raw_line in lines:
        # Bỏ dòng rỗng
        if not raw_line.strip() or raw_line.strip().startswith("mode"):
            continue

        # Xác định độ thụt dòng (số space hoặc tab)
        indent_level = len(raw_line) - len(raw_line.lstrip(" \t"))
        line = raw_line.strip()

        # === Nếu đang ở trong function mà indent < func_indent → kết thúc hàm ===
        if current_func and indent_level <= func_indent and not line.startswith("function "):
            current_func = None

        # === Bắt đầu hàm mới ===
        if line.startswith("function "):
            func_name = line.split()[1]
            current_func = func_name
            func_indent = indent_level
            functions[func_name] = []
            continue

        # === Gọi hàm ===
        if line.startswith("call "):
            func_name = line.split()[1]
            target = functions[current_func] if current_func else java_code
            target.append(f"{func_name}();")
            continue

        # === print ===
        if line.startswith("print "):
            content = line[len("print "):].strip()
            target = functions[current_func] if current_func else java_code
            target.append(f'System.out.println({to_java_expr(content)});')
            continue

        # === apu / tran ===
        if line.startswith(("apu ", "tran ")):
            target = functions[current_func] if current_func else java_code
            target.append(f'System.out.println("[CMD] {escape_quotes(line)}");')
            continue

        # === Biến gán ===
        if " is " in line:
            var, expr = line.split(" is ", 1)
            target = functions[current_func] if current_func else java_code
            target.append(f"var {var.strip()} = {expr.strip()};")
            continue

        # === Biểu thức số học độc lập ===
        if re.match(r'^[0-9\+\-\*/\s]+$', line):
            target = functions[current_func] if current_func else java_code
            target.append(f'System.out.println({line});')
            continue

    # === Sinh mã Java ===
    java_src = []
    java_src.append("public class BybyJIT {")
    java_src.append("    public static void main(String[] args) {")
    for l in java_code:
        java_src.append("        " + l)
    java_src.append("    }")

    for func_name, body in functions.items():
        java_src.append(f"    public static void {func_name}() {{")
        for l in body:
            java_src.append("        " + l)
        java_src.append("    }")

    java_src.append("}")
    return "\n".join(java_src)


def to_java_expr(expr: str) -> str:
    """Chuyển biểu thức BybyLang thành cú pháp hợp lệ Java."""
    if expr.startswith('"') and expr.endswith('"'):
        return '"' + expr[1:-1].replace('"', '\\"') + '"'
    if re.match(r'^[0-9\+\-\*/\s]+$', expr):
        return expr
    return '"' + expr.replace('"', '\\"') + '"'


def escape_quotes(s: str) -> str:
    return s.replace('"', '\\"')


def runJava(java_src):
    javafile = "BybyJIT.java"
    with open(javafile, "w") as f:
        f.write(java_src)
    print("[*] Đã tạo file BybyJIT.java")

    subprocess.run(["javac", javafile], check=True)
    subprocess.run(["java", "BybyJIT"], check=True)


def main():
    with open("main.bybylang") as f:
        src = f.read()
    java_src = parse_bybylang(src)
    print(java_src)
    runJava(java_src)


if __name__ == "__main__":
    main()