import Foundation

// Original stories shared by the DEBUG fixture and the separate screenshot tests.
#if DEBUG
enum StoreShotScene: String {
    case paper = "texture-paper", kraft = "texture-kraft", linen = "texture-linen"
    case continuation, widget, backup, recap, statistics, annotation, shelf, search
    case tags = "shelf-tags"

    static var requested: Self? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-testing"), args.contains("--ui-test-store-screenshots"),
              let i = args.firstIndex(of: "--ui-test-store-scene"), args.indices.contains(i + 1) else { return nil }
        return Self(rawValue: args[i + 1])
    }
    static let statisticsDate = Date(timeIntervalSince1970: 1_792_929_600) // 2026-10-25 12:00 UTC
}
enum StoreShotPage: String, CaseIterable {
    case bookDetails = "book-details", readerSettings = "reader-settings"
    case settings, libraryHome = "library-home", reader

    static var requested: Self? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-testing"), args.contains("--ui-test-store-screenshots"),
              let index = args.firstIndex(of: "--ui-test-page-scene"), args.indices.contains(index + 1) else { return nil }
        return Self(rawValue: args[index + 1])
    }
}
struct StoreShotBook: Decodable { let title: String; let text: String }
struct StoreShotFixture: Decodable {
    let language: String; let author: String; let folders: [String]; let books: [StoreShotBook]
    let notes: [[String]]; let bookmark: String; let progressChapters: [String]; let mainChapters: [String]
    static func localized(_ language: String) throws -> Self {
        let fixtures = try JSONDecoder().decode([String: Self].self, from: Data(#"""
{
  "zh-Hant": {
    "language": "zh-Hant",
    "region": "TW",
    "storefront": "TWN",
    "author": "月讀原創",
    "folders": [
      "故事",
      "隨筆"
    ],
    "books": [
      {
        "title": "月光下的歸途",
        "text": "月光下的歸途\n\n第一章 末班車\n\n林舟走出車站時，最後一班公車剛剛離開。紅色尾燈在路口停了一會兒，轉過彎便不見了。\n\n他站在站牌下面，翻開手機。父親半小時前傳來一則訊息：鑰匙放在老地方，鍋裡有湯。\n\n林舟回了一個「好」，把行李箱的拉桿收起來，提過路邊一小段正在翻修的石階。車站到家並不遠。他小時候走過很多次，只是隔了這些年，記憶裡的路似乎比眼前的窄一些。\n\n河堤上的樹長高了。原先賣報紙的亭子換成一家花店，鐵捲門已經放下，門前還留著兩桶沒來得及收走的菊花。林舟經過時，桶裡的水晃了一下，映出被枝葉切碎的月亮。\n\n他本可以叫一輛車，但今晚沒什麼需要趕的。\n\n第二章 夾在書裡的車票\n\n走到老街，林舟看見許叔的書店還亮著燈。\n\n門上的風鈴是舊的。他推門進去時，那聲音和多年前沒有什麼不同，先是清脆的一下，然後兩片薄銅輕輕碰著，慢慢停下來。\n\n許叔正蹲在櫃檯後找膠帶，聽見動靜，扶著櫃沿站起來。\n\n「這麼晚回來？」\n\n「車誤點了。您怎麼還沒關門？」\n\n「收拾這幾箱書，挪出一條能走的路。」許叔看了看他的行李箱，笑道，「你倒是正好，幫我把門口那箱搬進來。」\n\n紙箱比林舟想的輕，裡面大多是薄薄的舊書。最上面一本的封皮翹起來，書背上貼著透明膠帶。他把箱子放到櫃檯邊，順手將它抽了出來。\n\n「這本還在。」\n\n「你認得？」\n\n林舟沒有立即回答。他翻到中間，書頁間滑出一張淺藍色的車票，落在櫃檯上。\n\n那是一張十多年前的短途車票，起點就是他剛剛下車的車站。背面有一行用鉛筆寫的小字：下次從這裡接著看。\n\n字跡擠在窄窄的空白裡，最後一個字幾乎寫出了邊緣。他認出那個總要多繞一圈的「看」字，不由得笑了一聲。\n\n「我的。」\n\n許叔戴上眼鏡，湊近看了一眼。\n\n「那就拿走吧。這書在店裡等得夠久了。」\n\n林舟想起自己離開的那個下午。他坐在門邊讀書，父親在外面按自行車鈴，催他回家拿行李。他用車票夾住書頁，想著過幾天總會回來。\n\n後來那些「過幾天」，連在一起，成了很長的一段日子。\n\n他把車票重新夾好，問這本書多少錢。許叔擺擺手，又低頭去封下一只箱子。\n\n「下回來，替我帶一碗街口的餛飩。少放胡椒。」\n\n第三章 燈下\n\n書店關門後，兩個人在巷口分開。許叔往河邊走，林舟提著行李箱，拐進通往家的小路。\n\n院門右邊第三塊磚鬆著。他蹲下去，把手指伸進磚縫，摸到了套著紅繩的鑰匙。父親說的老地方，竟然還是這裡。\n\n廚房有一盞小燈。湯盛在帶蓋的白瓷碗裡，碗底壓著一張便條：涼了熱一熱，別將就。\n\n林舟把湯倒進小鍋，開了最小的火。水氣一點點爬上鍋沿，他靠在桌邊，拆掉舊書外面鬆動的膠帶。\n\n父親從裡屋出來，肩上披著外套。\n\n「聽見門響了。一路順利？」\n\n「順利。」林舟抬頭，「明早我去買餛飩，你要幾兩？」\n\n父親想了一下：「二兩。再帶兩個燒餅。」\n\n說完，他伸手把桌上搖晃的燈座轉正，回屋去了。\n\n林舟坐下來，把車票放到燈邊，從夾著的那一頁繼續讀。故事裡的那個人剛走過一座橋，還不知道橋的另一頭有什麼。\n\n窗外有人騎車經過，車鏈輕輕響著。小鍋裡的湯開始冒泡，他拿書籤夾好位置，起身去關火。\n\n月亮已經移過了屋簷，院子裡亮了一小片。\n"
      },
      {
        "title": "雨後小站",
        "text": "雨後小站\n\n第一章 留在月臺上的人\n\n雨落下來的時候，小站剛送走午後的列車。沈清抱著一箱給學校的圖書，站在屋簷下面，看水沿著鐵皮邊緣連成一條細線。\n\n站長搬出一張木凳，將摺好的報紙墊在短了一點的椅腳下面。他按了按，確認不會搖晃，才讓她坐。\n\n紙箱上寫著三年級，藍色記號筆已經被雨暈開了一點。兩個人聽著雨敲在站牌背面，遠處的山慢慢看不清了。\n\n第二章 借來的傘\n\n值班室裡有一把很大的黑傘，傘柄磨得光亮。站長說，這是昨天有人留在車上的，對方說先讓需要的人用。\n\n沈清撐開傘，發現傘骨上繫著一小截紅線。她抱著紙箱走出月臺，回頭看時，站長正在擦窗玻璃上的水。\n\n雨水打在傘面上，像許多人一起輕輕翻書。她想著教室後面那只空書櫃，腳步比來時快了一點。\n\n幾個孩子跑來幫忙搬書，一邊猜裡面會不會有講海的故事。門邊的傘還滴著水。\n\n第三章 晴天的回信\n\n第二天，沈清帶著傘和孩子們的畫回到車站。畫裡有火車、彩虹，還有一把大得足以遮住整間教室的黑傘。\n\n站長把畫貼在門上。午後列車進站時，那一點紅線已經繫在另一把舊傘上。\n"
      },
      {
        "title": "山間來信",
        "text": "山間來信\n\n第一章 信箱裡的春天\n\n山路修好以後，村口仍留著那只綠色的舊信箱。每週三，送報的阿姨會繞到這裡，給陳伯捎來一封信。\n\n外孫在海邊讀書。信紙有時帶著很淡的鹹味，有時夾著一張車票。他把每個信封都放進餅乾盒，盒底墊著乾燥的松針。\n\n這一次，信裡問山上的桃樹開花沒有。陳伯看見枝頭幾顆鼓起來的芽，在日曆上認真畫了一個圈。\n\n第二章 回信\n\n陳伯寫字很慢。一頁信紙寫了一個下午，他沒有說天氣冷，只說今年的花可能會多開幾天，讓孩子回來時也能趕上。\n\n鄰家的小女孩來借剪刀，看見桌上的信，問能不能畫一朵花。他把信紙轉過去，留出右下角的一小塊空白。\n\n女孩畫了五片花瓣，還畫了一片像小船的葉子。陳伯說山裡沒有這樣的葉子。女孩想了想，說那是替海邊的人畫的。\n\n週三早上，送報阿姨笑著說，這封信走得再遠，山裡的春天也不會散。\n\n第三章 花開的時候\n\n又過了一週，桃花真的開了。陳伯拍了三次，照片裡總有一半是天空。\n\n外孫說，天空讓他想起小時候的院子。陳伯把手機舉向樹梢，讓風替自己回答。\n"
      },
      {
        "title": "舊城午後",
        "text": "舊城午後\n\n第一章 修錶店\n\n週末的舊城安靜下來。陸遙停在修錶店前，聽見裡面許多細小的滴答聲。母親的舊手錶走慢了，錶面還留著一道淺淺的刮痕。\n\n第二章 一杯淡茶\n\n師傅倒了一杯淡茶。陸遙想起母親總把錶調快五分鐘，長大後才知道，母親只是想多留一點從容。\n\n她坐到茶涼，等牆上最小的鐘也走過整點，才把手錶戴回手腕。\n\n第三章 回去的路\n\n離開時，銅鈴輕輕響了一聲。那天她繞遠路回家，給母親帶了一小束新開的洋桔梗。\n"
      },
      {
        "title": "海邊的燈",
        "text": "海邊的燈\n\n第一章 候潮\n\n小漁港每到傍晚就亮起一排燈。程安把畫架靠在堤岸邊，試著畫下水面上被風揉碎的顏色。每次抬頭，海都和剛才不一樣。\n\n第二章 燈亮以後\n\n老人說，燈不是為了照亮整片海，只是讓人知道岸在哪裡。程安把這句話記在畫紙背面。\n\n回旅館時，她看見小餐館的蒸氣和燈光一起落到路面，忽然覺得那也是一處渡口。\n\n第三章 留白\n\n第二天，她在海與天空之間留下一小塊紙的白色。老人收到照片後，只回了一句：看見燈了。\n"
      },
      {
        "title": "冬日散步",
        "text": "冬日散步\n\n第一章 曬太陽的長椅\n\n冬天的公園比別的季節清楚。周寧沿湖邊慢慢走，看見帶著保溫杯的奶奶坐在向陽的一端，看鴿子在草地上找食物。\n\n第二章 一條新路\n\n奶奶說，湖對面的臘梅開了。周寧本來只是出門買菜，想了想，沿著那條背風的路繞了過去。\n\n淡黃色的花瓣挨著深色樹枝，香氣很輕，只有站近了才能聞到。\n\n第三章 帶回家\n\n回程時，長椅上留著一小片陽光。那一天的午飯和平常沒有不同，只是她在窗邊多坐了一會兒。\n"
      }
    ],
    "mainChapters": [
      "第一章 末班車",
      "第二章 夾在書裡的車票",
      "第三章 燈下"
    ],
    "progressChapters": [
      "第二章 借來的傘",
      "第二章 回信"
    ],
    "notes": [
      [
        "他本可以叫一輛車，但今晚沒什麼需要趕的。",
        "慢一點，也是一種回家的方式。"
      ],
      [
        "後來那些「過幾天」，連在一起，成了很長的一段日子。",
        "把想做的小事，留一點時間給今天。"
      ],
      [
        "月亮已經移過了屋簷，院子裡亮了一小片。",
        "喜歡這個安靜的結尾。"
      ]
    ],
    "bookmark": "林舟坐下來，把車票放到燈邊",
    "session": "E2E28F6F-1CE1-4CB9-9113-5B6CA86F2FC3"
  },
  "en": {
    "language": "en",
    "region": "US",
    "storefront": "USA",
    "author": "Moonread Originals",
    "folders": [
      "Stories",
      "Essays"
    ],
    "books": [
      {
        "title": "The Moonlit Way Home",
        "text": "The Moonlit Way Home\n\nChapter 1 The Last Bus\n\nWhen Lin Zhou stepped out of the station, the last bus was pulling away. Its red lights paused at the crossing, turned the corner, and disappeared.\n\nHe stood beneath the bus stop sign and checked his phone. Half an hour earlier, his father had sent a message: The key is in the usual place. There is soup on the stove.\n\nLin replied, “All right,” lowered the handle of his suitcase, and carried it over a short flight of steps under repair. Home was not far from the station. He had walked this road many times as a child, though after so many years it seemed wider than the road he remembered.\n\nThe trees along the river had grown taller. The old newspaper kiosk was now a flower shop, its shutter already down. Two buckets of chrysanthemums still stood outside. As he passed, the water trembled, holding fragments of the moon between the leaves.\n\nHe could have called a taxi, but there was no hurry tonight.\n\nChapter 2 The Ticket in the Book\n\nOn the old street, Lin saw that Uncle Xu's bookshop was still lit.\n\nThe wind chime above the door was the same old one. When he pushed the door open, it sounded just as it had years ago: one clear note, then the soft tapping of two thin copper leaves, slowly coming to rest.\n\nUncle Xu was crouching behind the counter, looking for tape. At the sound, he steadied himself against the counter and stood up.\n\n“Back so late?”\n\n“The train was delayed. Why are you still open?”\n\n“Sorting these boxes, trying to make a path through.” Uncle Xu glanced at the suitcase and smiled. “Good timing. Bring that box by the door inside for me.”\n\nThe box was lighter than Lin expected, mostly filled with slim old books. The cover of the top one curled at the corners, and clear tape ran along its spine. He set the box beside the counter and lifted the book out.\n\n“This one is still here.”\n\n“You know it?”\n\nLin did not answer at once. He opened the book near the middle. A pale blue ticket slipped from between the pages and landed on the counter.\n\nIt was a short train ticket, more than ten years old. The journey began at the very station where he had just arrived. On the back, a small pencil note read: Start here next time.\n\nThe writing crowded the narrow space, the final character almost slipping over the edge. He recognized the extra loop he always gave that last word and laughed softly.\n\n“Mine.”\n\nUncle Xu put on his glasses and leaned closer.\n\n“Then take it. The book has waited here long enough.”\n\nLin remembered the afternoon he had left. He had been reading beside the door while his father rang a bicycle bell outside, urging him home to fetch his luggage. He had marked the page with his ticket, thinking he would return in a few days.\n\nAll those “in a few days” had joined together into a long stretch of years.\n\nHe tucked the ticket back between the pages and asked the price. Uncle Xu waved a hand and bent over the next box.\n\n“Bring me a bowl of dumplings from the corner next time. Not too much pepper.”\n\nChapter 3 By the Lamp\n\nAfter the shop closed, they parted at the mouth of the lane. Uncle Xu went toward the river. Lin picked up his suitcase and turned onto the path home.\n\nThe third brick to the right of the gate was loose. He crouched, slipped his fingers into the gap, and found the key on its red cord. The usual place his father had mentioned was still the same place.\n\nA small light was on in the kitchen. Soup waited in a covered white bowl. Beneath it was a note: Warm it up if it is cold. Eat properly.\n\nLin poured the soup into a pan and turned the heat low. Steam climbed slowly around the rim. Leaning against the table, he peeled the loose tape from the old book.\n\nHis father came out of the bedroom with a coat over his shoulders.\n\n“Heard the door. Was the journey all right?”\n\n“It was.” Lin looked up. “I will get dumplings tomorrow. How many would you like?”\n\nHis father considered. “A small bowl. And two sesame buns.”\n\nHe reached over to straighten the unsteady lamp and went back to his room.\n\nLin Zhou sat down and laid the ticket beside the lamp. He began again from the marked page. Someone in the story had just crossed a bridge, not yet knowing what waited on the other side.\n\nA bicycle passed outside, its chain softly clicking. The soup began to bubble. Lin marked his place and stood up to turn off the stove.\n\nThe moon had passed the eaves, leaving a small patch of light in the courtyard.\n"
      },
      {
        "title": "The Station After Rain",
        "text": "The Station After Rain\n\nChapter 1 Waiting on the Platform\n\nThe rain began just after the afternoon train had left. Shen Qing stood beneath the station roof, holding a box of books for the village school. Water ran from the edge of the roof in a thin, unbroken thread.\n\nThe station keeper brought out a wooden stool. One leg was short, so he folded an old newspaper beneath it. Only after testing it with his hand did he invite her to sit.\n\nBlue ink on the box was beginning to spread. They listened to the rain tapping against the station sign as the distant hills faded from view.\n\nChapter 2 A Borrowed Umbrella\n\nThere was a large black umbrella in the office, its handle polished smooth. Someone had left it on a train the day before. When the station keeper called, its owner had said to lend it to whoever needed it.\n\nShen opened it and noticed a short red thread tied to one of the ribs. Carrying the books against her chest, she stepped onto the platform. Behind her, the station keeper was wiping water from a window.\n\nThe rain sounded like many people quietly turning pages. Thinking of the empty bookcase at the back of her classroom, she began to walk a little faster.\n\nAt the school, children hurried out to help. They wondered if any of the books contained stories about the sea. The umbrella stood by the door, still dripping.\n\nChapter 3 An Answer in Sunlight\n\nThe next morning, Shen returned with the umbrella and a drawing from the children. It showed a train, a rainbow, and an umbrella large enough to shelter their whole classroom.\n\nThe station keeper pinned it to his door. When the afternoon train arrived, the red thread had already been tied to another old umbrella.\n"
      },
      {
        "title": "Letters from the Hills",
        "text": "Letters from the Hills\n\nChapter 1 Spring in the Letterbox\n\nEven after the mountain road was repaired, the old green letterbox remained at the village entrance. Every Wednesday, the woman who delivered newspapers stopped there with a letter for Mr. Chen.\n\nHis grandson was studying by the sea. Sometimes a letter held a faint trace of salt, sometimes a train ticket. Mr. Chen kept every envelope in a biscuit tin lined with dry pine needles.\n\nThis time, the boy asked whether the peach tree had flowered. Mr. Chen went outside to look. Seeing the small swollen buds, he carefully circled a date on the calendar.\n\nChapter 2 A Reply\n\nMr. Chen wrote slowly. A single page took him all afternoon. He did not mention the cold. Instead, he wrote that the blossoms might last a little longer this year, perhaps long enough for the boy to see them.\n\nThe little girl next door came to borrow scissors. When she saw the letter, she asked if she could draw a flower. He turned the paper and left a small space in the lower corner.\n\nShe drew five petals and a leaf shaped like a boat. He said there were no leaves like that in the hills. After thinking for a moment, she said it was a leaf for someone who lived by the sea.\n\nOn Wednesday, the delivery woman smiled at the address. However far this letter traveled, she said, it would carry spring from the hills.\n\nChapter 3 When the Flowers Open\n\nA week later, the peach tree flowered. Mr. Chen took three photographs, and half of every picture was sky.\n\nHis grandson called to say he liked them. The sky reminded him of the old courtyard. Mr. Chen lifted the phone toward the branches and let the wind answer for him.\n"
      },
      {
        "title": "An Afternoon in the Old Town",
        "text": "An Afternoon in the Old Town\n\nChapter 1 The Watch Repair Shop\n\nOn weekends the old town grew quiet. Lu Yao stopped outside a watch repair shop and heard many small ticking sounds. Her mother had changed the strap on this watch twice, but a faint scratch still marked its face.\n\nChapter 2 A Cup of Weak Tea\n\nThe watchmaker poured a cup of weak tea. Lu remembered how her mother always set the watch five minutes fast. As a child she had thought those minutes could prevent her from being late. Now she understood that her mother had simply wanted a little room to breathe.\n\nShe stayed until the tea was cool and the smallest clock on the wall had passed the hour.\n\nChapter 3 The Longer Way Home\n\nA copper bell sounded as she left. She did not set the watch fast. That afternoon she took the longer way home and brought her mother a small bunch of flowers.\n"
      },
      {
        "title": "A Light by the Sea",
        "text": "A Light by the Sea\n\nChapter 1 Waiting for the Tide\n\nEvery evening a row of lamps lit the little harbor. Cheng An placed her easel against the sea wall and tried to paint the colors broken by the wind. Whenever she looked up, the water had changed.\n\nChapter 2 After the Lamps Come On\n\nThe old fisherman said a lamp did not need to light the whole sea. It only needed to show where the shore was. Cheng wrote this on the back of her painting.\n\nOn her way to the inn, she passed a small restaurant. Steam and light fell together through an open window. She thought that, too, was a kind of landing place.\n\nChapter 3 A Space Left White\n\nThe next morning, she left a small patch of white paper between sea and sky. Much later, the fisherman replied to her photograph with a single line: I can see the light.\n"
      },
      {
        "title": "A Winter Walk",
        "text": "A Winter Walk\n\nChapter 1 A Bench in the Sun\n\nIn winter, the park seemed clearer than in other seasons. Zhou Ning walked beside the lake and saw the old woman with her flask, sitting at the sunny end of a bench and watching pigeons search the grass.\n\nChapter 2 A Different Path\n\nThe old woman said the wintersweet was flowering across the lake. Zhou had only meant to buy vegetables, but she decided to take the sheltered path around the water.\n\nPale yellow petals rested beside dark branches. Their scent was so light that she had to step close to notice it.\n\nChapter 3 Something to Bring Home\n\nOn the way back, sunlight still lay on the empty bench. Lunch that day was much like any other. Only afterward, she sat a little longer beside the window.\n"
      }
    ],
    "mainChapters": [
      "Chapter 1 The Last Bus",
      "Chapter 2 The Ticket in the Book",
      "Chapter 3 By the Lamp"
    ],
    "progressChapters": [
      "Chapter 2 A Borrowed Umbrella",
      "Chapter 2 A Reply"
    ],
    "notes": [
      [
        "He could have called a taxi, but there was no hurry tonight.",
        "Taking your time can be a way of coming home."
      ],
      [
        "All those “in a few days” had joined together into a long stretch of years.",
        "Leave a little time today for the small things you want to do."
      ],
      [
        "The moon had passed the eaves, leaving a small patch of light in the courtyard.",
        "I like the quietness of this ending."
      ]
    ],
    "bookmark": "Lin Zhou sat down and laid the ticket beside the lamp.",
    "session": "7D381C59-48C4-4BB1-9FC8-A8C0B3A682F2"
  },
  "zh-Hans": {
    "language": "zh-Hans",
    "region": "CN",
    "storefront": "CHN",
    "author": "月读原创",
    "folders": [
      "故事",
      "随笔"
    ],
    "mainChapters": [
      "第一章 末班车",
      "第二章 夹在书里的车票",
      "第三章 灯下"
    ],
    "progressChapters": [
      "第二章 借来的伞",
      "第二章 回信"
    ],
    "notes": [
      [
        "他本可以叫一辆车，但今晚没什么需要赶的。",
        "慢一点，也是一种回家的方式。"
      ],
      [
        "后来那些“过几天”，连在一起，成了很长的一段日子。",
        "把想做的小事，留一点时间给今天。"
      ],
      [
        "月亮已经移过了屋檐，院子里亮了一小片。",
        "喜欢这个安静的结尾。"
      ]
    ],
    "bookmark": "林舟坐下来，把车票放到灯边",
    "session": "163E3D4A-54E5-4A27-B7F7-8D1D5D59E65D",
    "books": [
      {
        "title": "月光下的归途",
        "text": "月光下的归途\n\n第一章 末班车\n\n林舟走出车站时，最后一班公交刚刚离开。红色尾灯在路口停了一会儿，转过弯便不见了。\n\n他站在站牌下面，翻开手机。父亲半小时前发来一条消息：钥匙放在老地方，锅里有汤。\n\n林舟回了一个“好”，把行李箱的拉杆收起来，提过路边一小段正在翻修的石阶。车站到家并不远。他小时候走过很多次，只是隔了这些年，记忆里的路似乎比眼前的窄一些。\n\n河堤上的树长高了。原先卖报纸的亭子换成一家花店，卷帘门已经放下，门前还留着两桶没来得及收走的菊花。林舟经过时，桶里的水晃了一下，映出被枝叶切碎的月亮。\n\n他本可以叫一辆车，但今晚没什么需要赶的。\n\n第二章 夹在书里的车票\n\n走到老街，林舟看见许叔的书店还亮着灯。\n\n门上的风铃是旧的。他推门进去时，那声音和多年前没有什么不同，先是清脆的一下，然后两片薄铜轻轻碰着，慢慢停下来。\n\n许叔正蹲在柜台后找胶带，听见动静，扶着柜沿站起来。\n\n“这么晚回来？”\n\n“车晚点了。您怎么还没关门？”\n\n“收拾这几箱书，挪出一条能走的路。”许叔看了看他的行李箱，笑道，“你倒是正好，帮我把门口那箱搬进来。”\n\n纸箱比林舟想的轻，里面大多是薄薄的旧书。最上面一本的封皮翘起来，书脊上贴着透明胶。他把箱子放到柜台边，顺手将它抽了出来。\n\n“这本还在。”\n\n“你认得？”\n\n林舟没有立即回答。他翻到中间，纸页间滑出一张浅蓝色的车票，落在柜台上。\n\n那是一张十多年前的短途票，起点就是他刚刚下车的车站。背面有一行用铅笔写的小字：下次从这里接着看。\n\n字迹挤在窄窄的空白里，最后一个字几乎写出了边缘。他认出那个总要多绕一圈的“看”字，不由得笑了一声。\n\n“我的。”\n\n许叔戴上眼镜，凑近看了一眼。\n\n“那就拿走吧。这书在店里等得够久了。”\n\n林舟想起自己离开的那个下午。他坐在门边读书，父亲在外面按自行车铃，催他回家拿行李。他用车票夹住书页，想着过几天总会回来。\n\n后来那些“过几天”，连在一起，成了很长的一段日子。\n\n他把车票重新夹好，问这本书多少钱。许叔摆摆手，又低头去封下一只箱子。\n\n“下回来，替我带一碗街口的馄饨。少放胡椒。”\n\n第三章 灯下\n\n书店关门后，两个人在巷口分开。许叔往河边走，林舟提着行李箱，拐进通往家的小路。\n\n院门右边第三块砖松着。他蹲下去，把手指伸进砖缝，摸到了套着红绳的钥匙。父亲说的老地方，竟然还是这里。\n\n厨房有一盏小灯。汤盛在带盖的白瓷碗里，碗底压着一张便签：凉了热一热，别凑合。\n\n林舟把汤倒进小锅，开了最小的火。水汽一点点爬上锅沿，他靠在桌边，拆掉旧书外面松动的胶带。\n\n父亲从里屋出来，肩上披着外套。\n\n“听见门响了。一路顺利？”\n\n“顺利。”林舟抬头，“明早我去买馄饨，你要几两？”\n\n父亲想了一下：“二两。再带两个烧饼。”\n\n说完，他伸手把桌上摇晃的灯座转正，回屋去了。\n\n林舟坐下来，把车票放到灯边，从夹着的那一页继续读。故事里的那个人刚走过一座桥，还不知道桥的另一头有什么。\n\n窗外有人骑车经过，车链轻轻响着。小锅里的汤开始冒泡，他拿书签好位置，起身去关火。\n\n月亮已经移过了屋檐，院子里亮了一小片。\n"
      },
      {
        "title": "雨后小站",
        "text": "雨后小站\n\n第一章 留在站台上的人\n\n雨落下来的时候，小站刚送走午后的列车。沈清抱着一箱给学校的图书，站在屋檐下面，看水沿着铁皮边缘连成一条细线。\n\n站长从值班室搬出一张木凳。凳子的一条腿短了些，他叠好一片旧报纸塞在下面，又伸手按了按，确认不会摇晃，才让她坐。\n\n“等人来接？”他问。\n\n沈清摇头，说桥那边还有一段路，等雨小一些再走。箱子上写着三年级，蓝色记号笔已经被雨洇开了一点。\n\n站长找来一块干净的塑料布，把纸箱仔细包住。两个人没有再说话，只听着雨敲在站牌背面。远处的山慢慢看不清了。\n\n第二章 借来的伞\n\n值班室里有一把很大的黑伞，伞柄磨得光亮。站长说，这是昨天有人留在车上的，他打过电话，那个人说先让需要的人用。\n\n沈清撑开伞，发现伞骨上系着一小截红线。她把箱子抱在胸前，走出站台，回头看时，站长正在擦窗玻璃上的水。\n\n桥边的河涨了一些。雨水打在伞面上，像许多人一起轻轻翻书。她想着教室后面那只空书柜，脚步比来时快了一点。\n\n学校的门没有关。几个孩子跑过来帮她搬箱子，一边猜里面会不会有讲海的故事。她把伞收在门边，红线还滴着水。\n\n第三章 晴天的回信\n\n第二天早上，沈清带着伞和一张孩子们画的画回到车站。画里有火车、彩虹，还有一把大得足以遮住整间教室的黑伞。\n\n站长把画贴在值班室门上。他说，这封回信比地址容易认。风吹过站台，带来晒干的石头和青草的气味。\n\n午后的列车准时进站。沈清在窗边挥手，看见那一点红线已经系在另一把旧伞上。\n"
      },
      {
        "title": "山间来信",
        "text": "山间来信\n\n第一章 邮箱里的春天\n\n山路修好以后，村口仍留着那只绿色的旧邮箱。每周三，送报的阿姨会绕到这里，给没有手机的陈伯捎来一封信。\n\n陈伯的外孙在海边读书。信纸有时带着很淡的咸味，有时夹着一张车票。他把每个信封都放进饼干盒，盒底垫着干燥的松针。\n\n这一次，信里问山上的桃树开花没有。陈伯走到院门外看了看，枝头只有几颗鼓起来的芽。他回来，在日历上认真画了一个圈。\n\n傍晚，他把收音机搬到窗边。天气预报说夜里会降温，他想了很久，最后给桃树裹上一层旧棉布，像给晚归的人加件外套。\n\n第二章 回信\n\n陈伯写字很慢。一页信纸写了一个下午，他没有说天气冷，只说今年的花可能会多开几天，让孩子回来的时候也能赶上。\n\n邻居家的小女孩过来借剪刀，看见桌上的信，问能不能画一朵花。他把信纸转过去，留出右下角的一小块空白。\n\n女孩画了五片花瓣，还在旁边画了一只像小船的叶子。陈伯说，山里没有这样的叶子。女孩想了想，说那是替海边的人画的。\n\n周三早上，他把信交给送报阿姨。她站在车旁读了一眼地址，笑着说，这封信走得再远，山里的春天也不会散。\n\n第三章 花开的时候\n\n又过了一个星期，桃花真的开了。陈伯拿着小相机站在树下，拍了三次，照片里总有一半是天空。\n\n外孙打来电话，说照片很好，天空让人想起小时候的院子。陈伯没有说话，把手机举向树梢，让风替自己回答。\n\n那天晚上，饼干盒里又多了一个信封。松针仍然带着清香。\n"
      },
      {
        "title": "旧城午后",
        "text": "旧城午后\n\n第一章 修表铺\n\n周末的旧城安静下来。路边的小店把半扇门留给阳光，另外半扇挂着一串铜铃。陆遥停在修表铺前，听见里面有许多细小的滴答声。\n\n她带来的是母亲的旧手表，表带已经换过两次，表盘上仍留着一道浅浅的划痕。师傅把眼镜架低，问她是不是又进了水。\n\n“只是走慢了。”她说。\n\n师傅点点头，把表放在一块蓝绒布上。柜台后的墙上，十几只钟指着不同的时间。他说，有些钟还在等主人回来。\n\n第二章 一杯淡茶\n\n检查需要一会儿。师傅给陆遥倒了一杯淡茶，杯沿很薄，托在手里几乎没有重量。巷子里有人推车经过，车轮压着石缝，一下一下。\n\n她想起母亲总把这只表调快五分钟。小时候以为那五分钟能拦住迟到，长大后才知道，母亲只是想多留一点从容。\n\n师傅换好零件，把表贴在耳边听了一会儿。他说，不必赶，下午的日头还在窗台上。\n\n陆遥没有立刻走。她坐到茶凉，等墙上那只最小的钟也走过整点，才把手表戴回腕上。\n\n第三章 回去的路\n\n离开的时候，铜铃轻轻响了一声。旧城的影子比来时长了些，卖花的摊位正在收伞。\n\n她看了一眼表，没有把时间调快。那天她绕远路回家，给母亲带了一小束新开的洋桔梗。\n"
      },
      {
        "title": "海边的灯",
        "text": "海边的灯\n\n第一章 候潮\n\n小渔港每到傍晚就亮起一排灯。程安把画架靠在堤岸边，试着画下水面上那些被风揉碎的颜色。每次抬头，海都和刚才不一样。\n\n卖鱼饵的老人告诉她，今天涨潮晚，可以慢慢画。他用一只倒扣的木箱当凳子，坐在旁边修一张小网。\n\n程安问，岸边最远的那盏灯为什么总是先亮。老人抬手指了指，说那里以前是渡口，回家的人最早看见它。\n\n第二章 灯亮以后\n\n天色渐深，画纸上的蓝色再也调不准了。程安收起画笔，和老人一起望着海面。第一盏灯亮起来的时候，近处的一条船也转过了方向。\n\n老人说，灯不是为了照亮整片海，只是让人知道岸在哪里。程安把这句话记在画纸背面，没有加引号。\n\n回旅馆的路上，她经过一家还开着的小饭馆。厨房里有人把窗推开，蒸汽和灯光一起落到路面。她忽然觉得，那也是一处渡口。\n\n第三章 留白\n\n第二天，程安没有给那幅画添上灯。她在海与天空之间留了一小块纸的白色，让它安静地亮着。\n\n离开渔港时，她把画的照片寄给老人。过了很久收到回复，只有一句话：看见灯了。\n"
      },
      {
        "title": "冬日散步",
        "text": "冬日散步\n\n第一章 晒太阳的长椅\n\n冬天的公园比别的季节清楚。树枝间露出整片天空，长椅上的木纹也被低低的阳光照得分明。周宁把围巾绕好，沿湖边慢慢走。\n\n每天经过这里，总能遇见一位带着保温杯的奶奶。她不喂鸽子，只坐在向阳的一端，看它们在草地上找吃的。\n\n那天奶奶朝旁边挪了挪，空出一块位置。周宁坐下，听见杯盖打开时很轻的一声响。茶的热气在空气里停了一下，就散开了。\n\n第二章 一条新路\n\n奶奶说，湖对面有几株蜡梅开了。从这边绕过去要多走一刻钟，但那一段路背风，也有好看的石头。\n\n周宁本来只是出门买菜，袋子里还放着一把葱。她想了想，沿着奶奶说的方向走去。湖水贴着岸边结了一层薄冰，像没有写字的纸。\n\n花确实开了。淡黄色的花瓣挨着深色树枝，香气很轻，只有站近了才能闻到。她给长椅那边拍了一张照片，又把手机放进口袋。\n\n第三章 带回家\n\n回程时，奶奶已经离开。长椅上留着一小片阳光，杯子放过的地方颜色深一些。\n\n周宁提着菜继续往前走。那一天的午饭和平常没有不同，只是窗边多坐了一会儿。\n"
      }
    ]
  }
}

"""#.utf8))
        guard let value = fixtures[language] else { throw CocoaError(.coderReadCorrupt) }
        return value
    }
}
#endif
