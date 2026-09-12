using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace CodexDual {
 // A conservative, lossless editor, not a TOML serializer. Unrelated values are
 // scanned as opaque balanced expressions. Ambiguous managed structures fail closed.
 public sealed class TomlConfig {
  sealed class Entry { public int Start, End; public string[] Path; }
  sealed class Table { public string[] Path; public int End; }
  readonly string source;
  readonly Dictionary<string,Entry> entries = new Dictionary<string,Entry>(StringComparer.Ordinal);
  readonly Dictionary<string,Table> tables = new Dictionary<string,Table>(StringComparer.Ordinal);
  readonly List<string[]> arrays = new List<string[]>();
  int firstHeader;
  static string Id(string[] path) { return String.Join("\u001f",path); }
  static bool Prefix(string[] a,string[] b) { return a.Length <= b.Length && a.SequenceEqual(b.Take(a.Length)); }
  static Exception Invalid() { return new FormatException("配置结构无法安全编辑；请检查 TOML 语法及受管理字段，原文件未改写。"); }
  public TomlConfig(string text) {
   source = text; firstHeader = text.Length;
   string[] scope = new string[0]; Table table = new Table { Path=scope, End=text.Length }; tables[""]=table;
   int i=0;
   while(i<text.Length) {
    while(i<text.Length && Char.IsWhiteSpace(text[i])) i++;
    if(i==text.Length) break;
    if(text[i]=='#') { while(i<text.Length && text[i]!='\n') i++; continue; }
    int start=i, equal=-1, last=i; char quote='\0'; bool triple=false, comment=false; int square=0, curly=0;
    for(;i<text.Length;i++) {
     char c=text[i];
     if(comment) { if(c=='\n') { comment=false; if(square==0 && curly==0) break; } continue; }
     if(quote!='\0') {
      if(quote=='"' && c=='\\') { if(++i>=text.Length) throw Invalid(); last=i+1; continue; }
      if(c==quote) {
       if(!triple) quote='\0';
       else if(i+2<text.Length && text[i+1]==quote && text[i+2]==quote) {
        i+=2; while(i+1<text.Length && text[i+1]==quote && i-start<text.Length) i++;
        quote='\0'; triple=false;
       }
      } else if((c=='\n'||c=='\r')&&!triple) throw Invalid();
      last=i+1; continue;
     }
     if(c=='#') { comment=true; continue; }
     if(c=='\'' || c=='"') { quote=c; triple=i+2<text.Length && text[i+1]==c && text[i+2]==c; if(triple) i+=2; }
     else if(c=='[') square++; else if(c==']') square--;
     else if(c=='{') curly++; else if(c=='}') curly--;
     else if(c=='=' && equal<0 && square==0 && curly==0) equal=i;
     if(square<0 || curly<0) throw Invalid();
     if(c=='\n' && square==0 && curly==0) break;
     if(!Char.IsWhiteSpace(c)) last=i+1;
    }
    if(quote!='\0'||square!=0||curly!=0) throw Invalid();
    string statement=text.Substring(start,last-start).Trim();
    if(statement.StartsWith("[",StringComparison.Ordinal)) {
     bool array=statement.StartsWith("[[",StringComparison.Ordinal);
     int edge=array?2:1;
     if(!statement.EndsWith(array?"]]":"]",StringComparison.Ordinal)) throw Invalid();
     scope=ParsePath(statement.Substring(edge,statement.Length-edge*2));
     table.End=start; if(firstHeader==text.Length) firstHeader=start;
     if(array) arrays.Add(scope);
     bool inArray=arrays.Any(p=>Prefix(p,scope));
     table=new Table {Path=scope,End=text.Length};
     if(!inArray) { if(tables.ContainsKey(Id(scope))) throw Invalid(); tables[Id(scope)]=table; }
    } else {
     if(equal<0 || equal>=last-1) throw Invalid();
     string[] key=scope.Concat(ParsePath(text.Substring(start,equal-start))).ToArray();
     int value=equal+1; while(value<last && Char.IsWhiteSpace(text[value])) value++;
     if(value==last) throw Invalid();
     if(!arrays.Any(p=>Prefix(p,scope))) {
      if(entries.ContainsKey(Id(key))) throw Invalid();
      entries[Id(key)]=new Entry {Start=value,End=last,Path=key};
     }
    }
   }
  }
  public static string[] ParsePath(string text) {
   List<string> keys=new List<string>(); int i=0;
   while(i<text.Length) {
    while(i<text.Length && Char.IsWhiteSpace(text[i])) i++;
    if(i==text.Length) throw Invalid();
    int start=i;
    if(text[i]=='"'||text[i]=='\'') {
     char quote=text[i++]; bool closed=false;
     while(i<text.Length) { if(quote=='"' && text[i]=='\\') { i+=2; continue; } if(text[i++]==quote) {closed=true;break;} }
     if(!closed) throw Invalid();
     keys.Add(Decode(text.Substring(start,i-start)));
    } else {
     while(i<text.Length && (Char.IsLetterOrDigit(text[i]) && text[i]<128 || text[i]=='_' || text[i]=='-')) i++;
     if(i==start) throw Invalid(); keys.Add(text.Substring(start,i-start));
    }
    if(keys[keys.Count-1].Contains("\u001f")) throw Invalid();
    while(i<text.Length && Char.IsWhiteSpace(text[i])) i++;
    if(i==text.Length) break;
    if(text[i++]!='.' || i==text.Length) throw Invalid();
   }
   if(keys.Count==0) throw Invalid(); return keys.ToArray();
  }
  public static string Decode(string value) {
   if(value.Length<2 || value[0]!=value[value.Length-1] || (value[0]!='"'&&value[0]!='\'')) throw Invalid();
   string inside=value.Substring(1,value.Length-2);
   if(value[0]=='\'') { if(inside.Contains("'")||inside.Contains("\n")||inside.Contains("\r")) throw Invalid(); return inside; }
   StringBuilder result=new StringBuilder();
   for(int i=0;i<inside.Length;i++) {
    char c=inside[i]; if(c=='"'||c<32) throw Invalid();
    if(c!='\\') {result.Append(c);continue;}
    if(++i==inside.Length) throw Invalid();
    switch(inside[i]) {
     case '"': result.Append('"');break; case '\\': result.Append('\\');break;
     case 'n': result.Append('\n');break;case 'r': result.Append('\r');break;case 't': result.Append('\t');break;
     case 'b': result.Append('\b');break;case 'f': result.Append('\f');break;
     case 'u': case 'U':
      int n=inside[i]=='u'?4:8; if(i+n>=inside.Length) throw Invalid();
      int point; if(!Int32.TryParse(inside.Substring(i+1,n),System.Globalization.NumberStyles.HexNumber,null,out point)) throw Invalid();
      try{result.Append(Char.ConvertFromUtf32(point));}catch{throw Invalid();} i+=n;break;
     default: throw Invalid();
    }
   }
   return result.ToString();
  }
  public string GetString(string dottedPath) {
   Entry e; if(!entries.TryGetValue(Id(ParsePath(dottedPath)),out e)) return null;
   return Decode(source.Substring(e.Start,e.End-e.Start));
  }
  public bool HasPrefix(string dottedPath) {
   string[] path=ParsePath(dottedPath);
   return entries.Values.Any(e=>Prefix(path,e.Path)) || tables.Values.Any(t=>Prefix(path,t.Path)) || arrays.Any(p=>Prefix(path,p));
  }
  public string Set(string dottedPath,string literal) {
   string[] path=ParsePath(dottedPath); string key=Id(path);
   if(arrays.Any(p=>Prefix(p,path)||Prefix(path,p))) throw Invalid();
   foreach(var other in entries.Values) {
    if(Id(other.Path)!=key && (Prefix(path,other.Path)||Prefix(other.Path,path))) throw Invalid();
   }
   foreach(var t in tables.Values) if(Prefix(path,t.Path)) throw Invalid();
   Entry e;
   if(entries.TryGetValue(key,out e)) {
    string old=source.Substring(e.Start,e.End-e.Start);
    if(old!="true" && old!="false") Decode(old); // Managed fields must be simple scalars.
    return source.Substring(0,e.Start)+literal+source.Substring(e.End);
   }
   string[] parent=path.Take(path.Length-1).ToArray(); Table target;
   string newline=source.Contains("\r\n")?"\r\n":"\n";
   string assignment=QuoteKey(path.Last())+" = "+literal+newline;
   if(tables.TryGetValue(Id(parent),out target)) {
    int at=parent.Length==0?firstHeader:target.End;
    string lead=at>0 && source[at-1]!='\n'?newline:"";
    return source.Substring(0,at)+lead+assignment+source.Substring(at);
   }
   if(entries.Values.Any(v=>Prefix(parent,v.Path))) throw Invalid(); // Dotted/inline parent cannot be re-declared.
   return source+(source.EndsWith("\n",StringComparison.Ordinal)?"":newline)+newline+"["+String.Join(".",parent.Select(QuoteKey))+ "]"+newline+assignment;
  }
  static string QuoteKey(string key) { return Regex.IsMatch(key,@"^[A-Za-z0-9_-]+$")?key:"\""+key.Replace("\\","\\\\").Replace("\"","\\\"")+"\""; }
 }
}
