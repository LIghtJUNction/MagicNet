def blocked_ai_node_tag:
  test("中国|大陆|内地|香港|台湾|臺灣|台北|臺北|台中|臺中|台南|臺南|高雄|新竹|🇭🇰|🇹🇼|北京|上海|广州|深圳|天津|重庆|江苏|浙江|福建|山东|河南|河北|湖北|湖南|四川|陕西|安徽|辽宁|吉林|黑龙江|海南|广西|贵州|云南|山西|江西|(^|[^A-Za-z0-9])(?:Hong[ _-]?Kong(?:[ _-]?[0-9]+)?|HKG?[ _-]?[0-9]+|Taiwan|Taipei|Taichung|Tainan|Kaohsiung|Hsinchu|TW|TWN|China|Mainland|HK|HKG|CN|Beijing|Shanghai|Guangzhou|Shenzhen|Chongqing|Tianjin|Hebei|Shanxi|Liaoning|Jilin|Heilongjiang|Jiangsu|Zhejiang|Anhui|Fujian|Jiangxi|Shandong|Henan|Hubei|Hunan|Guangdong|Hainan|Sichuan|Guizhou|Yunnan|Shaanxi|Gansu|Qinghai|Inner[ _-]?Mongolia|Guangxi|Tibet|Ningxia|Xinjiang)([^A-Za-z0-9]|$)"; "i");
def us_node_tag:
  test("美国|美國|美西|美东|美東|洛杉矶|洛杉磯|圣何塞|聖何塞|西雅图|西雅圖|达拉斯|達拉斯|纽约|紐約|芝加哥|迈阿密|邁阿密|凤凰城|鳳凰城|亚特兰大|亞特蘭大|波特兰|波特蘭|丹佛|拉斯维加斯|拉斯維加斯|硅谷|🇺🇸|(^|[^A-Za-z0-9])(?:US|USA|United[ _-]?States|America|Los[ _-]?Angeles|San[ _-]?Jose|Seattle|Dallas|New[ _-]?York|Chicago|Washington|Miami|Phoenix|Atlanta|Portland|Denver|Las[ _-]?Vegas|Silicon[ _-]?Valley)([^A-Za-z0-9]|$)"; "i");
def japan_node_tag:
  test("日本|东京|東京|大阪|埼玉|名古屋|🇯🇵|(^|[^A-Za-z0-9])(?:JP|JPN|Japan|Tokyo|Osaka|Saitama|Nagoya)([^A-Za-z0-9]|$)"; "i");
def prioritize_ai_tags:
  . as $tags
  | ([$tags[]? | select(blocked_ai_node_tag | not)]) as $eligible
  | ([$eligible[] | select(us_node_tag)])
    + ([$eligible[] | select((us_node_tag | not) and japan_node_tag)])
    + ([$eligible[] | select((us_node_tag | not) and (japan_node_tag | not))]);
