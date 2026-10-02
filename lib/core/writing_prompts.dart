/// 每日一问：写作引子。
///
/// 空页面是写日记最大的障碍——不是不想写，是不知道从哪写起。
/// 所以这里准备的不是"深刻的好问题"，而是**多角度的入口**：
/// 事件、感受、人、感官细节、身体、反思、工作、感恩、想象、未来、换位、碎片。
///
/// 任何一个角度都可能让人突然想起今天真正值得记的那件事。
/// 引子本身不写进日记文件：它是写作的脚手架，不是日记的内容。
library;

import 'day.dart';

class WritingPrompt {
  const WritingPrompt(this.category, this.text);

  /// 角度，显示在问题上方。让用户知道这次是从哪个方向切入的。
  final String category;

  final String text;
}

/// 120 条引子，12 个角度各 10 条。
const List<WritingPrompt> kWritingPrompts = <WritingPrompt>[
  // ---- 今天发生了什么 ----
  WritingPrompt('今天发生了什么', '今天最占时间的一件事是什么？'),
  WritingPrompt('今天发生了什么', '今天有什么计划被打断了？'),
  WritingPrompt('今天发生了什么', '今天有没有哪一刻让你觉得「终于搞定了」？'),
  WritingPrompt('今天发生了什么', '今天做的哪件事，明天的你会感谢自己？'),
  WritingPrompt('今天发生了什么', '今天有没有什么小意外？'),
  WritingPrompt('今天发生了什么', '如果给今天写一个标题，会是什么？'),
  WritingPrompt('今天发生了什么', '今天有没有什么重复了很多次的动作？'),
  WritingPrompt('今天发生了什么', '今天的时间都去哪儿了？'),
  WritingPrompt('今天发生了什么', '今天有没有一件事和你预想的不一样？'),
  WritingPrompt('今天发生了什么', '今天有没有什么被你忽略掉的安排？'),

  // ---- 感受 ----
  WritingPrompt('感受', '今天情绪起伏最大的是哪一刻？'),
  WritingPrompt('感受', '今天有没有让你烦躁的小事？它真的值得烦躁吗？'),
  WritingPrompt('感受', '今天什么时候你最放松？'),
  WritingPrompt('感受', '今天有没有你在硬撑的时刻？'),
  WritingPrompt('感受', '今天有没有什么事让你突然很高兴？'),
  WritingPrompt('感受', '如果今天的心情是一种天气，会是什么？'),
  WritingPrompt('感受', '今天有没有什么情绪你还没消化完？'),
  WritingPrompt('感受', '今天有没有对谁忍住了没说出口的话？'),
  WritingPrompt('感受', '今天你对自己满意吗？'),
  WritingPrompt('感受', '今天最平静的一段时间你在做什么？'),

  // ---- 人 ----
  WritingPrompt('人', '今天和谁说了最多的话？'),
  WritingPrompt('人', '今天有没有谁的一句话让你记到现在？'),
  WritingPrompt('人', '今天有没有帮助过谁，或者被谁帮过？'),
  WritingPrompt('人', '今天有没有你想联系但没联系的人？'),
  WritingPrompt('人', '今天有没有哪个陌生人的举动让你注意到了？'),
  WritingPrompt('人', '今天有没有和谁产生了误解？'),
  WritingPrompt('人', '今天有没有谁让你觉得被理解了？'),
  WritingPrompt('人', '今天有没有你想道歉、或者想谢谢的人？'),
  WritingPrompt('人', '今天和家人有交流吗？聊了什么？'),
  WritingPrompt('人', '今天有没有谁的状态让你有点担心？'),

  // ---- 观察与细节 ----
  WritingPrompt('观察与细节', '今天你注意到的一个细节是什么？'),
  WritingPrompt('观察与细节', '今天听到的哪个声音印象最深？'),
  WritingPrompt('观察与细节', '今天吃的东西里，哪一口最好吃？'),
  WritingPrompt('观察与细节', '今天的光线是什么样的？'),
  WritingPrompt('观察与细节', '今天有没有闻到什么特别的气味？'),
  WritingPrompt('观察与细节', '今天路上看到的一个画面是什么？'),
  WritingPrompt('观察与细节', '今天摸到的东西里，哪个触感让你记住了？'),
  WritingPrompt('观察与细节', '今天你路过的地方有什么变化吗？'),
  WritingPrompt('观察与细节', '今天有没有什么东西的颜色让你多看了一眼？'),
  WritingPrompt('观察与细节', '今天最安静的时刻是什么时候？'),

  // ---- 身体 ----
  WritingPrompt('身体', '今天身体哪里最累？'),
  WritingPrompt('身体', '今天睡够了吗？醒来时是什么感觉？'),
  WritingPrompt('身体', '今天有没有哪个瞬间身体在提醒你该休息了？'),
  WritingPrompt('身体', '今天有没有好好吃饭？'),
  WritingPrompt('身体', '今天有没有出门走过一段路？'),
  WritingPrompt('身体', '今天什么时候你的身体是放松的？'),
  WritingPrompt('身体', '今天有没有什么疼痛或者不适？'),
  WritingPrompt('身体', '今天的呼吸在什么时候变得最深？'),
  WritingPrompt('身体', '今天你坐着的时间多还是站着的时间多？'),
  WritingPrompt('身体', '如果身体今天会说话，它会说什么？'),

  // ---- 思考与反思 ----
  WritingPrompt('思考与反思', '今天有没有改变你对某件事的看法？'),
  WritingPrompt('思考与反思', '今天有没有什么是你之前想错了的？'),
  WritingPrompt('思考与反思', '今天你反复想起的一个念头是什么？'),
  WritingPrompt('思考与反思', '今天有没有遇到一个你答不上来的问题？'),
  WritingPrompt('思考与反思', '今天有没有什么事让你重新理解了一个词？'),
  WritingPrompt('思考与反思', '今天做的决定里，哪个你事后觉得不太对？'),
  WritingPrompt('思考与反思', '今天有没有什么是你一直在逃避的？'),
  WritingPrompt('思考与反思', '今天你学到了什么以前不知道的事？'),
  WritingPrompt('思考与反思', '今天有没有什么让你觉得「这不合理」的事？'),
  WritingPrompt('思考与反思', '如果今天可以重来一遍，你会改哪里？'),

  // ---- 工作与学习 ----
  WritingPrompt('工作与学习', '今天推进得最顺利的一件事是什么？'),
  WritingPrompt('工作与学习', '今天卡在哪里了？卡住的真正原因是什么？'),
  WritingPrompt('工作与学习', '今天有没有什么是你其实可以拒绝的？'),
  WritingPrompt('工作与学习', '今天有没有学会一个新东西？'),
  WritingPrompt('工作与学习', '今天有没有帮别人解决了问题？'),
  WritingPrompt('工作与学习', '今天有没有什么反复出现的问题值得记下来？'),
  WritingPrompt('工作与学习', '今天有没有因为沟通不清楚白费了力气？'),
  WritingPrompt('工作与学习', '今天有没有哪件事其实比你以为的简单？'),
  WritingPrompt('工作与学习', '明天第一件事你打算做什么？'),
  WritingPrompt('工作与学习', '今天有没有因为别人的一句话改变了自己的做法？'),

  // ---- 感恩与小确幸 ----
  WritingPrompt('感恩与小确幸', '今天有什么小事让你觉得很幸运？'),
  WritingPrompt('感恩与小确幸', '今天有没有谁为你做了一件小事？'),
  WritingPrompt('感恩与小确幸', '今天有没有什么东西让你觉得「贵是值得的」？'),
  WritingPrompt('感恩与小确幸', '今天有没有一个瞬间让你觉得生活还不错？'),
  WritingPrompt('感恩与小确幸', '今天有没有什么你拥有、但平时忽略了的东西？'),
  WritingPrompt('感恩与小确幸', '今天有没有什么让你笑了？'),
  WritingPrompt('感恩与小确幸', '今天有没有什么让你觉得很方便的小发明？'),
  WritingPrompt('感恩与小确幸', '今天有没有什么食物让你觉得幸福？'),
  WritingPrompt('感恩与小确幸', '今天有没有什么你本来会抱怨、其实值得感谢的事？'),
  WritingPrompt('感恩与小确幸', '今天有什么是你希望以后也能一直有的？'),

  // ---- 想象与假设 ----
  WritingPrompt('想象与假设', '如果今天可以多出两个小时，你会用来做什么？'),
  WritingPrompt('想象与假设', '如果今天可以给一个人写一封信，会写给谁？'),
  WritingPrompt('想象与假设', '如果你今天遇到十年前的自己，你会说什么？'),
  WritingPrompt('想象与假设', '如果今天要拍成一段纪录片，哪一段最值得留？'),
  WritingPrompt('想象与假设', '假设明天完全不用工作，你最想做什么？'),
  WritingPrompt('想象与假设', '如果你的今天要讲给一个小孩听，你会怎么讲？'),
  WritingPrompt('想象与假设', '如果今天只能留下一张照片，你会留哪一刻？'),
  WritingPrompt('想象与假设', '如果可以把今天的一个瞬间装进瓶子，你选哪个？'),
  WritingPrompt('想象与假设', '如果今天是一道菜，它是什么味道的？'),
  WritingPrompt('想象与假设', '如果你要为一个陌生人描述你的今天，会从哪里开始？'),

  // ---- 未来与计划 ----
  WritingPrompt('未来与计划', '明天最想做成的一件事是什么？'),
  WritingPrompt('未来与计划', '有没有什么你一直想做、却迟迟没开始的事？'),
  WritingPrompt('未来与计划', '这周结束前你想完成什么？'),
  WritingPrompt('未来与计划', '有没有什么习惯你想捡回来？'),
  WritingPrompt('未来与计划', '有没有什么你想减少的事情？'),
  WritingPrompt('未来与计划', '如果一个月后的你回头看今天，你最希望看到什么？'),
  WritingPrompt('未来与计划', '有没有什么决定你一直在拖延？'),
  WritingPrompt('未来与计划', '你希望今年结束时的自己是什么样子？'),
  WritingPrompt('未来与计划', '有没有什么你想去、还没去的地方？'),
  WritingPrompt('未来与计划', '有没有什么你最近想学的东西？'),

  // ---- 换位与对话 ----
  WritingPrompt('换位与对话', '如果今天的事发生在别人身上，你会怎么劝他？'),
  WritingPrompt('换位与对话', '今天有没有什么你只看到了自己这一面的事？'),
  WritingPrompt('换位与对话', '如果你是被你抱怨的那个人，你会怎么想？'),
  WritingPrompt('换位与对话', '今天有没有什么是你替别人做了、但没说出口的？'),
  WritingPrompt('换位与对话', '如果今天的行为要当成一个例子，是哪一课？'),
  WritingPrompt('换位与对话', '今天有没有什么你误解了别人的地方？'),
  WritingPrompt('换位与对话', '今天有没有什么事，你希望别人能理解你？'),
  WritingPrompt('换位与对话', '如果你要为自己今天辩解，你会说什么？'),
  WritingPrompt('换位与对话', '今天有没有什么你其实想被看见的努力？'),
  WritingPrompt('换位与对话', '今天有没有谁的做法，你其实可以学一学？'),

  // ---- 随想与碎片 ----
  WritingPrompt('随想与碎片', '随便写一件今天想到的小事。'),
  WritingPrompt('随想与碎片', '今天有没有什么歌词或者句子在你脑子里循环？'),
  WritingPrompt('随想与碎片', '今天有没有做过一个很短的梦、或者白日梦？'),
  WritingPrompt('随想与碎片', '今天有没有什么让你突然想起很久以前的事？'),
  WritingPrompt('随想与碎片', '今天有没有什么让你觉得「人真奇怪」的瞬间？'),
  WritingPrompt('随想与碎片', '今天心里最吵的那个声音在说什么？'),
  WritingPrompt('随想与碎片', '今天有没有什么你明知道没用、但还是做了的事？'),
  WritingPrompt('随想与碎片', '今天有没有什么时候你觉得时间过得特别快或特别慢？'),
  WritingPrompt('随想与碎片', '今天有没有什么你更想留在心里、而不是写下来的？'),
  WritingPrompt('随想与碎片', '今天结束时，你想对自己说一句什么？'),
];

/// 所有角度，按在 [kWritingPrompts] 里出现的顺序。
List<String> get writingPromptCategories {
  final seen = <String>[];
  for (final prompt in kWritingPrompts) {
    if (!seen.contains(prompt.category)) seen.add(prompt.category);
  }
  return seen;
}

/// 取某一天的写作引子。
///
/// 三条刻意的性质：
///   * **同一天永远返回同一条**。做成随机的话，用户刚看到一个好问题、
///     切走再回来就换成了别的，会怀疑自己记错。
///   * **相邻日期不重复，而且落在不同角度上**。步长取得足够大且不是
///     每类条数的倍数，所以不会连着十天都在问同一类问题。
///   * **任意连续 N 天刚好覆盖全部 N 条**。靠的是步长与总数互质：
///     `day * step mod total` 此时是双射。
///
/// [offset] 是「换一个」的次数。它改变的是相位而不是步长，
/// 而相位步长同样与总数互质，所以换满一圈刚好遍历全部引子、不重不漏。
WritingPrompt promptForDate(DateTime date, {int offset = 0}) {
  final total = kWritingPrompts.length;
  final day = dateOnly(date).difference(DateTime(2020, 1, 1)).inDays;
  // 取模要保证非负：基准点之前的日期 inDays 是负数
  final index =
      ((day * _dayStride(total) + offset * _offsetStride(total)) % total +
              total) %
          total;
  return kWritingPrompts[index];
}

/// 日期步长。首选 37：和 120 互质，而且不是 10 的倍数——
/// 每个角度正好 10 条，所以它会一次跨过 3~4 个角度，
/// 相邻日期必定落在不同角度上。
int _dayStride(int total) => _coprimeStride(
      total,
      const <int>[37, 53, 71, 91, 103, 113, 7, 11, 13, 17, 19, 23],
    );

/// 「换一个」的相位步长。
int _offsetStride(int total) => _coprimeStride(
      total,
      const <int>[131, 97, 89, 83, 79, 73, 67, 61, 59, 47, 43, 41],
    );

/// 从候选里挑一个与 [total] 互质的。全部不适配就退化成 1（顺序取），
/// 这样即使以后增删引子导致总数变化，也只是分布变差，不会出错。
int _coprimeStride(int total, List<int> candidates) {
  for (final candidate in candidates) {
    if (_gcd(candidate, total) == 1) return candidate;
  }
  return 1;
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);
