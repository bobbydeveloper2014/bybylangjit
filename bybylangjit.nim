# bybylang.nim - BybyLang JIT executable + Nim code generation + auto compile release
# Hỗ trợ cơ chế function: define function bằng "function NAME" ... kết thúc bằng một dòng chỉ chứa NAME
import strutils, os, osproc, tables, sequtils

# --------------------------
# Helpers
# --------------------------
proc stripQuotes(s: string): string =
  if s.len >= 2 and s[0] == '"' and s[^1] == '"':
    return s[1..^2]
  else:
    return s

proc parseIntSafe(s: string): int =
  try:
    return parseInt(s)
  except:
    return 0

# --------------------------
# Types
# --------------------------
type
  Mode = enum
    Low, Mid, High

  Token = object
    sym: string
    text: string
    indent: int
# --------------------------
# RAM / Bus / Pins giả lập
# --------------------------
const RAM_SIZE = 1024
var RAM: array[0..RAM_SIZE-1, int]
var BUS: seq[string] = @[]
var Pins: array[0..31, bool]

var ignoreErrors = false
var quietMode = false

# function table lưu body token
var funcTable = initTable[string, seq[Token]]()

# --------------------------
# Lexer đơn giản
# --------------------------

proc tokenizeLine(line: string): Token =
  var tok: Token
  # Đếm số khoảng trắng đầu dòng để xác định cấp indent
  tok.indent = line.len - line.strip(chars={' ', '\t'}).len

  # Loại bỏ khoảng trắng đầu cuối để xử lý cú pháp
  let clean = line.strip()

  if clean.len == 0:
    tok.sym = "empty"
    tok.text = ""
  elif clean.startsWith("function "):
    tok.sym = "function"
    tok.text = clean.replace("function ", "")
  elif clean.startsWith("print "):
    tok.sym = "print"
    tok.text = clean
  else:
    tok.sym = "other"
    tok.text = clean

  return tok

# Đọc file .bybylang và chuyển thành danh sách tokens
proc tokenizeFile(filename: string): seq[Token] =
  var tokens: seq[Token] = @[]
  for line in lines(filename):
    let t = tokenizeLine(line)
    tokens.add(t)
  return tokens
# --------------------------
# Hardware-level functions
# --------------------------
proc apuTran(name: string, payload: string) =
  BUS.add(payload)
  if not quietMode:
    echo "[APU-TRAN] ", name, " -> ", payload

proc apuMem(action: string, target: string, value: string) =
  let ramAddr = parseIntSafe(target.replace("RAM",""))
  if ramAddr < 0 or ramAddr >= RAM_SIZE:
    if not ignoreErrors:
      echo "[ERROR] Invalid RAM address: ", ramAddr
      quit(1)
    return
  if action == "write":
    RAM[ramAddr] = parseIntSafe(value)
    if not quietMode:
      echo "[APU-MEM] RAM[", ramAddr, "] <- ", value
  elif action == "read":
    if not quietMode:
      echo "[APU-MEM] RAM[", ramAddr, "] -> ", RAM[ramAddr]

proc apuCore(mode: int, code: string) =
  if not quietMode:
    echo "[APU-CORE] Mode: ", mode, ", running: ", code

proc apuPin(pin: int, state: string) =
  if pin < 0 or pin > 31:
    if not ignoreErrors:
      echo "[ERROR] Invalid pin: ", pin
      quit(1)
    return
  Pins[pin] = (state == "high")
  if not quietMode:
    echo "[APU-PIN] pin ", pin, " set ", state

proc bitSend(bits: string) =
  BUS.add(bits)
  if not quietMode:
    echo "[BIT-SEND] ", bits

proc bitRecv() =
  if BUS.len > 0:
    let b = BUS[0]
    delete(BUS, 0)
    if not quietMode:
      echo "[BIT-RECV] ", b
  else:
    if not quietMode:
      echo "[BIT-RECV] empty"

proc memMap(target: string) =
  if not quietMode:
    echo "[MEM-MAP] ", target

proc memPush(target: string, value: string) =
  if not quietMode:
    echo "[MEM-PUSH] ", target, " <- ", value

proc tranPulse(pin: int, width: string) =
  if not quietMode:
    echo "[TRAN-PULSE] pin ", pin, " width ", width

# --------------------------
# Generate Nim code + compile to binary release
# --------------------------
proc generateNimCode(tokens: seq[Token], outFile: string) =
  # --- tách thân hàm bằng indent ---
  var funcBodiesLocal = initTable[string, seq[Token]]()
  var idx = 0

  # --- tách thân hàm bằng indent ---
  while idx < tokens.len:
    let t = tokens[idx]
    if t.sym == "function":
      let fname = t.text.strip()
      let baseIndent = t.indent
      var body: seq[Token] = @[]
      idx.inc
      while idx < tokens.len and tokens[idx].indent > baseIndent:
        body.add(tokens[idx])
        idx.inc
      funcBodiesLocal[fname] = body
    else:
      idx.inc

  # --- khởi tạo file ---
  var nimFile = outFile
  if not nimFile.endsWith(".nim"): nimFile &= ".nim"

  var code = newSeq[string]()
  code.add("import strutils, sequtils")
  code.add("const RAM_SIZE = 1024")
  code.add("var RAM: array[0..RAM_SIZE-1, int]")
  code.add("var BUS: seq[string] = @[]")
  code.add("var Pins: array[0..31, bool]")
  code.add("")
  code.add("proc stripQuotes(s: string): string =")
  code.add("  if s.len >= 2 and s[0] == '\"' and s[^1] == '\"':")
  code.add("    return s[1..^2]")
  code.add("  else:")
  code.add("    return s")
  code.add("")
  # --- proc HW ---
  code.add("proc apuTran(name: string, payload: string) =")
  code.add("  BUS.add(payload)")
  code.add("  echo \"[APU-TRAN] \", name, \" -> \", payload")
  code.add("")
  code.add("proc apuMem(action: string, target: string, value: string) =")
  code.add("  var ramAddr = parseInt(target.replace(\"RAM\", \"\"))")
  code.add("  if action == \"write\":")
  code.add("    RAM[ramAddr] = parseInt(value)")
  code.add("  elif action == \"read\":")
  code.add("    echo \"[APU-MEM] RAM[\", ramAddr, \"] -> \", RAM[ramAddr]")
  code.add("")
  code.add("proc apuCore(mode: int, code: string) =")
  code.add("  echo \"[APU-CORE] Mode:\", mode, \" run:\", code")
  code.add("")
  code.add("proc apuPin(pin: int, state: string) =")
  code.add("  Pins[pin] = (state == \"high\")")
  code.add("")
  code.add("proc bitSend(bits: string) =")
  code.add("  BUS.add(bits)")
  code.add("")
  code.add("proc bitRecv() =")
  code.add("  if BUS.len > 0:")
  code.add("    echo BUS[0]")
  code.add("    delete(BUS, 0)")
  code.add("  else:")
  code.add("    echo \"[BIT-RECV] empty\"")
  code.add("")
  code.add("proc memMap(target: string) =")
  code.add("  echo \"[MEM-MAP] \", target")
  code.add("")
  code.add("proc memPush(target: string, value: string) =")
  code.add("  echo \"[MEM-PUSH] \", target, \" <- \", value")
  code.add("")
  code.add("proc tranPulse(pin: int, width: string) =")
  code.add("  echo \"[TRAN-PULSE] pin \", pin, \" width \", width")
  code.add("")

  # --- thu thập tên hàm ---
  var funcNames: seq[string] = @[]
  for k, _ in funcBodiesLocal:
    funcNames.add(k)
  var varNames: seq[string] = @[]

  # --- 1. Sinh tất cả proc trước ---
  for k, v in funcBodiesLocal:
    code.add("")
    code.add("proc " & k & "() =")
    var localVars: seq[string] = @[]
    for tk in v:
      if tk.sym == "print":
        var raw = tk.text.replace("print", "").strip()
        code.add("  echo " & raw)
      elif tk.sym == "other":
        let line = tk.text.strip()
        if line.startsWith("call "):
          let fname = line.split()[1]
          if fname in funcNames:
            code.add("  " & fname & "()")
          else:
            code.add("  {.compileTimeError: \"Function " & fname & " not found\".}")
        elif line in funcNames:
          code.add("  " & line & "()")
        elif line.contains("="):
          let parts = line.split("=")
          if parts.len >= 2:
            let left = parts[0].strip()
            let right = parts[1..^1].join("=").strip()
            if left notin localVars:
              localVars.add(left)
              code.add("  var " & left & " = " & right)
            else:
              code.add("  " & left & " = " & right)
        else:
          discard
      else:
        discard

  # --- 2. Sinh top-level code ---
  code.add("")
  idx = 0
  while idx < tokens.len:
    let t = tokens[idx]
    if t.sym == "print":
      var raw = t.text.replace("print", "").strip()
      code.add("echo " & raw)
    elif t.sym == "other":
      let line = t.text.strip()
      # --- xử lý if ---
      if line.startsWith("if "):
        let baseIndent = t.indent
        code.add(line)
        var j = idx + 1
        while j < tokens.len and tokens[j].indent > baseIndent:
          let tk = tokens[j]
          let l2 = tk.text.strip()

          # lệnh bên trong khối if
          if tk.sym == "print":
            code.add("  echo " & tk.text.replace("print", "").strip())
          elif l2.startsWith("apu tran"):
            let parts = l2.split("with")
            let name = stripQuotes(parts[0].split()[2].strip())
            let payload = parts[1].strip()
            code.add("  apuTran(\"" & name & "\", " & payload & ")")
          elif l2.startsWith("apu mem"):
            let parts = l2.split("with")
            let left = parts[0].split()
            let action = left[2]
            let target = stripQuotes(left[3])
            let value = parts[1].strip()
            code.add("  apuMem(\"" & action & "\", \"" & target & "\", " & value & ")")
          elif l2.startsWith("apu core"):
            code.add("  apuCore(0, \"" & l2.replace("apu core", "").strip() & "\")")
          elif l2.startsWith("apu pin"):
            let p = l2.replace("apu pin", "").strip().split(",")
            code.add("  apuPin(" & p.join(", ") & ")")
          elif l2.startsWith("bit send"):
            code.add("  bitSend(" & l2.replace("bit send", "").strip() & ")")
          elif l2.startsWith("bit recv"):
            code.add("  bitRecv()")
          elif l2.startsWith("mem map"):
            code.add("  memMap(" & l2.replace("mem map", "").strip() & ")")
          elif l2.startsWith("mem push"):
            let p = l2.replace("mem push", "").strip().split(",")
            code.add("  memPush(" & p.join(", ") & ")")
          elif l2.startsWith("tran pulse"):
            let p = l2.replace("tran pulse", "").strip().split(",")
            code.add("  tranPulse(" & p.join(", ") & ")")
          elif l2.contains("="):
            let p = l2.split("=")
            if p.len >= 2:
              code.add("  " & p[0].strip() & " = " & p[1..^1].join("=").strip())
          j.inc
        idx = j - 1

      # --- xử lý elif ---
      elif line.startsWith("elif "):
        let baseIndent = t.indent
        code.add(line)
        var j = idx + 1
        while j < tokens.len and tokens[j].indent > baseIndent:
          let tk = tokens[j]
          let l2 = tk.text.strip()
          # xử lý như trong if
          if tk.sym == "print":
            code.add("  echo " & tk.text.replace("print", "").strip())
          elif l2.startsWith("apu tran"):
            let parts = l2.split("with")
            let name = stripQuotes(parts[0].split()[2].strip())
            let payload = parts[1].strip()
            code.add("  apuTran(\"" & name & "\", " & payload & ")")
          elif l2.startsWith("apu mem"):
            let parts = l2.split("with")
            let left = parts[0].split()
            let action = left[2]
            let target = stripQuotes(left[3])
            let value = parts[1].strip()
            code.add("  apuMem(\"" & action & "\", \"" & target & "\", " & value & ")")
          elif l2.startsWith("apu core"):
            code.add("  apuCore(0, \"" & l2.replace("apu core", "").strip() & "\")")
          elif l2.startsWith("apu pin"):
            let p = l2.replace("apu pin", "").strip().split(",")
            code.add("  apuPin(" & p.join(", ") & ")")
          elif l2.startsWith("bit send"):
            code.add("  bitSend(" & l2.replace("bit send", "").strip() & ")")
          elif l2.startsWith("bit recv"):
            code.add("  bitRecv()")
          elif l2.startsWith("mem map"):
            code.add("  memMap(" & l2.replace("mem map", "").strip() & ")")
          elif l2.startsWith("mem push"):
            let p = l2.replace("mem push", "").strip().split(",")
            code.add("  memPush(" & p.join(", ") & ")")
          elif l2.startsWith("tran pulse"):
            let p = l2.replace("tran pulse", "").strip().split(",")
            code.add("  tranPulse(" & p.join(", ") & ")")
          elif l2.contains("="):
            let p = l2.split("=")
            if p.len >= 2:
              code.add("  " & p[0].strip() & " = " & p[1..^1].join("=").strip())
          j.inc
        idx = j - 1

      # --- xử lý else ---
      elif line == "else:":
        let baseIndent = t.indent
        code.add(line)
        var j = idx + 1
        while j < tokens.len and tokens[j].indent > baseIndent:
          let tk = tokens[j]
          let l2 = tk.text.strip()
          # xử lý như trong if
          if tk.sym == "print":
            code.add("  echo " & tk.text.replace("print", "").strip())
          elif l2.startsWith("apu tran"):
            let parts = l2.split("with")
            let name = stripQuotes(parts[0].split()[2].strip())
            let payload = parts[1].strip()
            code.add("  apuTran(\"" & name & "\", " & payload & ")")
          elif l2.startsWith("apu mem"):
            let parts = l2.split("with")
            let left = parts[0].split()
            let action = left[2]
            let target = stripQuotes(left[3])
            let value = parts[1].strip()
            code.add("  apuMem(\"" & action & "\", \"" & target & "\", " & value & ")")
          elif l2.startsWith("apu core"):
            code.add("  apuCore(0, \"" & l2.replace("apu core", "").strip() & "\")")
          elif l2.startsWith("apu pin"):
            let p = l2.replace("apu pin", "").strip().split(",")
            code.add("  apuPin(" & p.join(", ") & ")")
          elif l2.startsWith("bit send"):
            code.add("  bitSend(" & l2.replace("bit send", "").strip() & ")")
          elif l2.startsWith("bit recv"):
            code.add("  bitRecv()")
          elif l2.startsWith("mem map"):
            code.add("  memMap(" & l2.replace("mem map", "").strip() & ")")
          elif l2.startsWith("mem push"):
            let p = l2.replace("mem push", "").strip().split(",")
            code.add("  memPush(" & p.join(", ") & ")")
          elif l2.startsWith("tran pulse"):
            let p = l2.replace("tran pulse", "").strip().split(",")
            code.add("  tranPulse(" & p.join(", ") & ")")
          elif l2.contains("="):
            let p = l2.split("=")
            if p.len >= 2:
              code.add("  " & p[0].strip() & " = " & p[1..^1].join("=").strip())
          j.inc
        idx = j - 1
      elif line.startsWith("call "):
        let fname = line.split()[1]
        if fname in funcNames:
          code.add(fname & "()")  # gọi trực tiếp, không echo
        else:
          code.add("{.compileTimeError: \"Function " & fname & " not found\".}")
      elif line.contains(" is "):
        let parts = line.split(" is ")
        let left = parts[0].strip()
        let right = parts[1..^1].join(" is ").strip()
        code.add("var " & left & " = " & right)
      elif line.startsWith("while true:"):
        let baseIndent = t.indent
        code.add(t.text)  # ghi nguyên dòng while true:
        var localVars: seq[string] = @[]

        var j = idx + 1
        while j < tokens.len and tokens[j].indent > baseIndent:
          let tk = tokens[j]

          if tk.sym == "print":
            var raw = tk.text.replace("print", "").strip()
            code.add("  echo " & raw)
          elif tk.sym == "other":
            let line = tk.text.strip()
            if line.startsWith("call "):
              let fname = line.split()[1]
              if fname in funcNames:
                code.add("  " & fname & "()")
              else:
                code.add("  {.compileTimeError: \"Function " & fname & " not found\".}")
            elif line in funcNames:
              code.add("  " & line & "()")
            elif line.contains("="):
              let parts = line.split("=")
              if parts.len >= 2:
                let left = parts[0].strip()
                let right = parts[1..^1].join("=").strip()
                if left notin localVars:
                  localVars.add(left)
                  code.add("  var " & left & " = " & right)
                else:
                  code.add("  " & left & " = " & right)
                        # --- if / elif / else ---
            elif line.startsWith("if "):
              code.add("  " & line & ":")
            elif line.startsWith("elif "):
              code.add("  " & line & ":")
            elif line == "else":
              code.add("  else:")
            # HW / BIT / MEM / TRAN
            elif line.startswith("apu tran"):
              let parts = line.split("with")
              let name = stripQuotes(parts[0].split()[2].strip())
              let payload = parts[1].strip()
              code.add("  apuTran(" & name & ", " & payload & ")")
            elif line.startswith("apu mem"):
              let parts = line.split("with")
              let left = parts[0].split()
              let action = left[2]
              let target = stripQuotes(left[3])
              let value = parts[1].strip()
              code.add("  apuMem(\"" & action & "\", \"" & target & "\", \"" & value & "\")")
            elif line.startswith("apu core"):
              code.add("  apuCore(1, \"run\")")
            elif line.startswith("apu pin"):
              let words = line.split()
              code.add("  apuPin(" & words[2] & ", \"" & words[4] & "\")")
            elif line.startswith("bit send"):
              code.add("  bitSend(\"" & line.split()[2] & "\")")
            elif line.startswith("bit recv"):
              code.add("  bitRecv()")
            elif line.startswith("mem map"):
              code.add("  memMap(\"" & stripQuotes(line.split()[2]) & "\")")
            elif line.startswith("mem push"):
              let parts = line.split("with")
              code.add("  memPush(\"" & stripQuotes(parts[0].split()[2]) & "\", \"" & parts[1].strip() & "\")")
            elif line.startswith("tran pulse"):
              let words = line.split()
              code.add("  tranPulse(" & words[3] & ", \"" & words[^1] & "\")")
            else:
              discard
          else:
            discard

          j.inc
        idx = j - 1
      elif line.startsWith("for "):
        # --- xử lý cú pháp range() ---
        var forLine = line
        if "range(" in forLine:
          let inside = forLine.split("range(")[1].split(")")[0]
          let parts = inside.split(",")
          if parts.len == 2:
            let start = parts[0].strip()
            let stop = parts[1].strip()
            forLine = forLine.replace("range(" & inside & ")", start & ".." & stop)

        let baseIndent = t.indent
        code.add(forLine)  # ví dụ: for i in 1..5:
        var j = idx + 1

        # --- xử lý các dòng bên trong for ---
        while j < tokens.len and tokens[j].indent > baseIndent:
          let tk = tokens[j]
          let l2 = tk.text.strip()

          # print
          if tk.sym == "print":
            code.add("  echo " & tk.text.replace("print", "").strip())

          # apu tran
          elif l2.startsWith("apu tran"):
            let parts = l2.split("with")
            let name = stripQuotes(parts[0].split()[2].strip())
            let payload = parts[1].strip()
            code.add("  apuTran(\"" & name & "\", " & payload & ")")

          # apu mem
          elif line.startsWith("apu mem"):
            let parts = line.split("with")
            let left = parts[0].split()
            let action = left[2]
            let target = stripQuotes(left[3])
            let value = parts[1].strip()
            code.add("apuMem(\"" & action & "\", \"" & target & "\", \"" & value & "\")")

          # bit send / recv
          elif l2.startsWith("bit send"):
            code.add("  bitSend(\"" & l2.split()[2] & "\")")
          elif l2.startsWith("bit recv"):
            code.add("  bitRecv()")

          # mem map / push
          elif l2.startsWith("mem map"):
            code.add("  memMap(\"" & l2.split()[2] & "\")")
          elif l2.startsWith("mem push"):
            let parts = l2.split("with")
            let target = stripQuotes(parts[0].split()[2])
            let value = parts[1].strip()
            code.add("  memPush(\"" & target & "\", \"" & value & "\")")

          # tran pulse
          elif l2.startsWith("tran pulse"):
            let parts = l2.split()
            code.add("  tranPulse(" & parts[2] & ", \"" & parts[3] & "\")")

          # nested if / elif / else
          elif l2.startsWith("if "):
            code.add("  " & l2)
          elif l2.startsWith("elif "):
            code.add("  " & l2)
          elif l2 == "else:":
            code.add("  else:")

          # phép gán
          elif l2.contains("="):
            let p = l2.split("=")
            if p.len >= 2:
              code.add("  var " & p[0].strip() & " = " & p[1..^1].join("=").strip())

          j.inc
        idx = j - 1
      # --------------------------
      # IF / ELIF / ELSE
      # --------------------------
      elif line.startsWith("apu tran"):
        let parts = line.split("with")
        let name = stripQuotes(parts[0].split()[2].strip())
        let payload = parts[1].strip()
        code.add("apuTran(\"" & name & "\", " & payload & ")")
      elif line.startsWith("apu mem"):
        let parts = line.split("with")
        let left = parts[0].split()
        let action = left[2]
        let target = stripQuotes(left[3])
        let value = parts[1].strip()
        code.add("apuMem(\"" & action & "\", \"" & target & "\", \"" & value & "\")")
      elif line.startsWith("apu core"):
        code.add("apuCore(1, \"run\")")
      elif line.startsWith("apu pin"):
        let words = line.split()
        code.add("apuPin(" & words[2] & ", \"" & words[4] & "\")")
      elif line.startsWith("bit send"):
        code.add("bitSend(\"" & line.split()[2] & "\")")
      elif line.startsWith("bit recv"):
        code.add("bitRecv()")
      elif line.startsWith("mem map"):
        code.add("memMap(\"" & stripQuotes(line.split()[2]) & "\")")
      elif line.startsWith("mem push"):
        let parts = line.split("with")
        code.add("memPush(\"" & stripQuotes(parts[0].split()[2]) & "\", \"" & parts[1].strip() & "\")")
      elif line.startsWith("tran pulse"):
        let words = line.split()
        code.add("tranPulse(" & words[3] & ", \"" & words[^1] & "\")")
      else:
        if line.startsWith("mode is"):
          let parts = line.split()
          if parts.len >= 3:
            let m = parseInt(parts[2])
            if m == 1:
              code.add("""echo "Mode 1: Low-level"""")
            elif m == 2:
              code.add("""echo "Mode 2: Mid-level"""")
            elif m == 3:
              code.add("""echo "Mode 3: High-level"""")
            elif m == 4:
              code.add("""echo "Mode 4: Web-level"""")
            else:
              code.add("echo \"Unknown mode: " & $m & "\"")
        else:
          code.add(line)
    idx.inc

    writeFile(nimFile, code.join("\n"))
# --------------------------
# Main
# --------------------------
proc main() =
  var inputFile = ""
  var args = commandLineParams()
  discard initTable[string, seq[Token]]()

  for i, a in args:
    if a == "--ignore-errors":
      ignoreErrors = true
    elif a == "--quiet":
      quietMode = true
    elif i == 0 or inputFile == "":
      inputFile = a

  if inputFile == "":
    echo "Usage: ./bybylang <file.bybylang> [--ignore-errors] [--quiet]"
    quit(1)

  if not fileExists(inputFile):
    echo "[ERROR] File not found: ", inputFile
    quit(1)

  let tokens = tokenizeFile(inputFile)

  # --- luôn compile sang Nim rồi JS ---
  let tmpNim = "tmp_bybylang.nim"
  generateNimCode(tokens, tmpNim)

  let tmpJS = "tmp_bybylang.nim.js"
  let cmdCompile = "nim js -d:nodejs --verbosity:0 -o:" & tmpJS & " " & tmpNim
  let resCompile = execProcess(cmdCompile)
  let resRun = execProcess("node " & tmpJS)
  echo resRun
main()
