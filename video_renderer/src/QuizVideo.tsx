import React from "react";
import {
  AbsoluteFill,
  Html5Audio,
  Img,
  OffthreadVideo,
  Sequence,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import {
  COUNTDOWN_FRAMES,
  FADE_FRAMES,
  FINAL_BACKGROUND_FRAMES,
  INTRO_FRAMES,
  QUESTION_LEAD_FRAMES,
  TRANSITION_FRAMES,
  introVideoFrames,
  questionTiming,
} from "./timing";
import { fitText } from "./textFit";
import type {
  QuizChoice,
  QuizVideoData,
  VideoPresentationAssets,
  VideoQuestion,
} from "./types";

const colors = {
  ink: "#10253d",
  deep: "#061a32",
  white: "#ffffff",
  paper: "#f7fbff",
  green: "#38a85b",
  greenDark: "#176e37",
  yellow: "#ffca3a",
  orange: "#f07828",
  muted: "#a9b8c7",
};

const badgeAccents = ["#8047c7", "#53a63b", "#f27a18", "#2686df"];

const Background: React.FC<{ source: string; dim?: number }> = ({
  source,
  dim = 0,
}) => (
  <AbsoluteFill>
    <Img
      src={staticFile(source)}
      style={{ width: "100%", height: "100%", objectFit: "cover" }}
    />
    {dim > 0 ? (
      <AbsoluteFill style={{ backgroundColor: `rgba(2, 14, 30, ${dim})` }} />
    ) : null}
  </AbsoluteFill>
);

const QuestionProgressBadge: React.FC<{
  current: number;
  total: number;
}> = ({ current, total }) => (
  <div
    style={{
      position: "absolute",
      top: 30,
      left: 30,
      width: 380,
      height: 92,
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      gap: 15,
      padding: "0 28px 0 16px",
      borderRadius: 46,
      backgroundColor: "rgba(255,255,255,0.96)",
      border: "4px solid rgba(55,139,210,0.65)",
      boxShadow: "0 8px 20px rgba(34,91,133,0.2)",
    }}
  >
    <div
      style={{
        width: 62,
        height: 62,
        flex: "0 0 62px",
        borderRadius: "50%",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        color: colors.white,
        backgroundColor: colors.orange,
        border: "4px solid #ffffff",
        boxShadow: "0 3px 9px rgba(0,0,0,0.25)",
        fontSize: 34,
        fontWeight: 900,
      }}
    >
      Q
    </div>
    <div
      style={{
        color: colors.ink,
        fontSize: 30,
        fontWeight: 900,
        whiteSpace: "nowrap",
      }}
    >
      Question {current} of {total}
    </div>
  </div>
);

const Timer: React.FC<{
  localFrame: number;
  countdownStart: number;
  revealStart: number;
  fps: number;
}> = ({ localFrame, countdownStart, revealStart, fps }) => {
  const countdownFrame = Math.max(0, localFrame - countdownStart);
  const active = localFrame >= countdownStart && localFrame < revealStart;
  const revealed = localFrame >= revealStart;
  const elapsed = Math.min(1, countdownFrame / COUNTDOWN_FRAMES);
  const remainingRatio = 1 - elapsed;
  const remaining = Math.max(
    1,
    Math.ceil((COUNTDOWN_FRAMES - countdownFrame) / fps),
  );

  return (
    <div
      style={{
        width: 132,
        height: 132,
        borderRadius: "50%",
        background: active
          ? `conic-gradient(${colors.yellow} ${remainingRatio * 360}deg, rgba(255,255,255,0.22) 0deg)`
          : revealed
            ? colors.green
            : "rgba(255,255,255,0.18)",
        padding: 9,
        boxShadow: "0 8px 18px rgba(0,0,0,0.35)",
      }}
    >
      <div
        style={{
          width: "100%",
          height: "100%",
          borderRadius: "50%",
          backgroundColor: revealed ? colors.green : colors.deep,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          color: colors.white,
          fontSize: 58,
          fontWeight: 900,
        }}
      >
        {active ? remaining : revealed ? <CheckMark /> : "..."}
      </div>
    </div>
  );
};

const CheckMark: React.FC = () => (
  <div
    style={{
      width: 50,
      height: 27,
      borderLeft: `10px solid ${colors.white}`,
      borderBottom: `10px solid ${colors.white}`,
      transform: "rotate(-45deg) translate(2px, -4px)",
    }}
  />
);

const ChoiceCard: React.FC<{
  choice: QuizChoice;
}> = ({ choice }) => {
  const labelFit = fitText({
    text: choice.label,
    maxWidth: 405,
    maxHeight: 62,
    maxFontSize: 40,
    minFontSize: 28,
    maxLines: 2,
    lineHeight: 1.05,
    fontFamily: '"DejaVu Sans"',
    fontWeight: 900,
  });
  return (
    <div
      style={{
        height: 354,
        borderRadius: 8,
        overflow: "hidden",
        backgroundColor: colors.paper,
        border: "4px solid rgba(255,255,255,0.94)",
        boxShadow: "0 12px 28px rgba(0,0,0,0.4)",
      }}
    >
      <div
        style={{
          height: 282,
          overflow: "hidden",
          backgroundColor: colors.white,
        }}
      >
        <Img
          src={staticFile(choice.image)}
          style={{
            width: "100%",
            height: "100%",
            objectFit: "contain",
            transform: "scale(1.2)",
          }}
        />
      </div>
      <div
        style={{
          height: 72,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          padding: "0 14px 4px",
          backgroundColor: colors.paper,
          color: colors.ink,
          fontSize: labelFit.fontSize,
          lineHeight: labelFit.lineHeight,
          fontWeight: 900,
          textAlign: "center",
          letterSpacing: 0,
        }}
      >
        {choice.label}
      </div>
    </div>
  );
};

const LandscapeChoiceCard: React.FC<{
  choice: QuizChoice;
  letter: string;
  badge: string;
  accent: string;
}> = ({ choice, letter, badge, accent }) => {
  const fitted = fitText({
    text: choice.label,
    maxWidth: 345,
    maxHeight: 92,
    maxFontSize: 40,
    minFontSize: 24,
    maxLines: 2,
    lineHeight: 1.08,
    fontFamily: '"DejaVu Sans"',
    fontWeight: 900,
  });
  return (
    <div
      style={{
        position: "relative",
        height: 500,
        overflow: "visible",
        borderRadius: 22,
        backgroundColor: "rgba(255,255,255,0.97)",
        border: `4px solid ${accent}`,
        boxShadow: "0 8px 20px rgba(27,72,105,0.2)",
      }}
    >
      <Img
        src={staticFile(choice.image)}
        style={{
          position: "absolute",
          top: 28,
          left: 38,
          width: 345,
          height: 340,
          objectFit: "contain",
          borderRadius: 15,
          backgroundColor: colors.white,
          border: "3px solid rgba(16,37,61,0.13)",
          boxShadow: "0 4px 10px rgba(27,72,105,0.14)",
        }}
      />
      <div
        style={{
          position: "absolute",
          left: 38,
          right: 38,
          top: 386,
          bottom: 22,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          color: colors.ink,
          fontSize: fitted.fontSize,
          lineHeight: fitted.lineHeight,
          fontWeight: 900,
          textAlign: "center",
          letterSpacing: 0,
        }}
      >
        {choice.label}
      </div>
      <div
        style={{
          position: "absolute",
          top: -18,
          left: -14,
          width: 88,
          height: 88,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <Img
          src={staticFile(badge)}
          style={{ position: "absolute", width: "100%", height: "100%" }}
        />
        <span
          style={{
            position: "relative",
            color: colors.white,
            fontSize: 42,
            fontWeight: 900,
            textShadow: "0 3px 3px rgba(0,0,0,0.45)",
          }}
        >
          {letter}
        </span>
      </div>
    </div>
  );
};

const LandscapeAnswerOverlay: React.FC<{
  answer: QuizChoice;
  explanation: string;
  revealProgress: number;
  explanationProgress: number;
}> = ({ answer, explanation, revealProgress, explanationProgress }) => {
  const answerFit = fitText({
    text: answer.label,
    maxWidth: 410,
    maxHeight: 108,
    maxFontSize: 48,
    minFontSize: 30,
    maxLines: 2,
    lineHeight: 1.08,
    fontFamily: '"DejaVu Sans"',
    fontWeight: 900,
  });
  const explanationFit = fitText({
    text: explanation,
    maxWidth: 735,
    maxHeight: 450,
    maxFontSize: 48,
    minFontSize: 30,
    maxLines: 7,
    lineHeight: 1.2,
    fontFamily: '"DejaVu Sans"',
    fontWeight: 800,
  });

  return (
    <div
      style={{
        position: "absolute",
        top: 220,
        left: 220,
        width: 1480,
        height: 720,
        overflow: "visible",
        borderRadius: 30,
        backgroundColor: "rgba(255,255,255,0.97)",
        border: "5px solid rgba(45,139,215,0.78)",
        boxShadow: "0 14px 34px rgba(27,72,105,0.28)",
        opacity: revealProgress,
        transform: `translateY(${(1 - revealProgress) * 45}px) scale(${0.97 + revealProgress * 0.03})`,
      }}
    >
      <div
        style={{
          position: "absolute",
          top: -38,
          left: 56,
          width: 82,
          height: 82,
          borderRadius: "50%",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          backgroundColor: colors.green,
          border: "6px solid #ffffff",
          boxShadow: "0 7px 16px rgba(0,0,0,0.24)",
        }}
      >
        <CheckMark />
      </div>
      <div
        style={{
          position: "absolute",
          top: 58,
          left: 58,
          bottom: 58,
          width: 450,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
        }}
      >
        <Img
          src={staticFile(answer.image)}
          style={{
            width: 430,
            height: 430,
            objectFit: "contain",
            borderRadius: 20,
            backgroundColor: colors.white,
            border: `5px solid ${colors.green}`,
            boxShadow: "0 8px 18px rgba(27,72,105,0.18)",
          }}
        />
        <div
          style={{
            width: 410,
            flex: 1,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            color: colors.ink,
            fontSize: answerFit.fontSize,
            lineHeight: answerFit.lineHeight,
            fontWeight: 900,
            textAlign: "center",
            letterSpacing: 0,
          }}
        >
          {answer.label}
        </div>
      </div>
      <div
        style={{
          position: "absolute",
          top: 72,
          bottom: 72,
          left: 565,
          width: 4,
          borderRadius: 2,
          backgroundColor: "rgba(45,139,215,0.28)",
        }}
      />
      <div
        style={{
          position: "absolute",
          top: 75,
          right: 75,
          bottom: 75,
          left: 635,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          color: colors.ink,
          fontSize: explanationFit.fontSize,
          lineHeight: explanationFit.lineHeight,
          fontWeight: 800,
          textAlign: "left",
          letterSpacing: 0,
          opacity: explanationProgress,
          transform: `translateY(${(1 - explanationProgress) * 20}px)`,
        }}
      >
        {explanation}
      </div>
    </div>
  );
};

const AnswerOverlay: React.FC<{
  answer: QuizChoice;
  explanation: string;
  revealProgress: number;
  explanationProgress: number;
}> = ({ answer, explanation, revealProgress, explanationProgress }) => {
  const explanationFit = fitText({
    text: explanation,
    maxWidth: 790,
    maxHeight: 245,
    maxFontSize: 50,
    minFontSize: 34,
    maxLines: 5,
    lineHeight: 1.18,
    fontFamily: '"DejaVu Sans"',
    fontWeight: 900,
  });
  return (
    <div
      style={{
        position: "absolute",
        top: 675,
        left: 70,
        right: 70,
        minHeight: 1090,
        borderRadius: 8,
        overflow: "hidden",
        backgroundColor: "rgba(247,251,255,0.97)",
        borderTop: `12px solid ${colors.green}`,
        borderBottom: `12px solid ${colors.yellow}`,
        boxShadow: "0 20px 50px rgba(0,0,0,0.52)",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        padding: "38px 48px 44px",
        opacity: revealProgress,
        transform: `translateY(${(1 - revealProgress) * 70}px) scale(${0.96 + revealProgress * 0.04})`,
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 22,
          color: colors.greenDark,
          fontSize: 31,
          fontWeight: 900,
          textTransform: "uppercase",
        }}
      >
        <div
          style={{
            width: 66,
            height: 66,
            borderRadius: "50%",
            backgroundColor: colors.green,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <CheckMark />
        </div>
        Correct answer
      </div>
      <div
        style={{
          width: 520,
          height: 520,
          marginTop: 30,
          backgroundColor: colors.white,
          border: `8px solid ${colors.green}`,
          borderRadius: 8,
          overflow: "hidden",
          boxShadow: "0 14px 30px rgba(0,0,0,0.25)",
        }}
      >
        <Img
          src={staticFile(answer.image)}
          style={{ width: "100%", height: "100%", objectFit: "contain" }}
        />
      </div>
      <div
        style={{
          color: colors.ink,
          fontSize: answer.label.length > 22 ? 39 : 48,
          lineHeight: 1.08,
          fontWeight: 900,
          textAlign: "center",
          marginTop: 24,
        }}
      >
        {answer.label}
      </div>
      <div
        style={{
          width: "100%",
          height: 3,
          backgroundColor: "#d5e0e8",
          margin: "28px 0 25px",
        }}
      />
      <div
        style={{
          color: colors.ink,
          fontSize: explanationFit.fontSize,
          lineHeight: explanationFit.lineHeight,
          fontWeight: 900,
          textAlign: "center",
          opacity: explanationProgress,
          transform: `translateY(${(1 - explanationProgress) * 24}px)`,
        }}
      >
        {explanation}
      </div>
    </div>
  );
};

const QuestionScene: React.FC<{
  question: VideoQuestion;
  totalQuestions: number;
  background: string;
  timerAudio: string;
  presentation: VideoPresentationAssets;
}> = ({ question, totalQuestions, background, timerAudio, presentation }) => {
  const frame = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  const landscape = width > height;
  const timing = questionTiming(question, fps);
  const entrance = spring({
    frame,
    fps,
    config: { damping: 18, stiffness: 120 },
  });
  const exitOpacity = interpolate(
    frame,
    [timing.contentFrames - FADE_FRAMES, timing.contentFrames],
    [1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  const revealProgress = spring({
    frame: Math.max(0, frame - timing.revealStart),
    fps,
    config: { damping: 18, stiffness: 120 },
  });
  const explanationProgress = spring({
    frame: Math.max(0, frame - timing.explanationStart),
    fps,
    config: { damping: 18, stiffness: 110 },
  });
  const answer = question.choices.find(
    (choice) => choice.choiceId === question.correctChoiceId,
  );
  if (!answer) {
    throw new Error(`Correct answer is missing for ${question.questionId}`);
  }
  const landscapeQuestionFit = fitText({
    text: question.question,
    maxWidth: 1420,
    maxHeight: 225,
    maxFontSize: 76,
    minFontSize: 42,
    maxLines: 3,
    lineHeight: 1.08,
    fontFamily: '"DejaVu Sans"',
    fontWeight: 900,
  });
  const portraitQuestionFit = fitText({
    text: question.question,
    maxWidth: 700,
    maxHeight: 500,
    maxFontSize: 68,
    minFontSize: 36,
    maxLines: 7,
    lineHeight: 1.12,
    fontFamily: '"DejaVu Sans"',
    fontWeight: 900,
  });

  return (
    <AbsoluteFill
      style={{
        opacity: exitOpacity,
        transform: `scale(${0.985 + entrance * 0.015})`,
        fontFamily: "DejaVu Sans, sans-serif",
      }}
    >
      <Background source={background} />
      <AbsoluteFill
        style={{
          background: landscape
            ? "rgba(255,255,255,0.025)"
            : "linear-gradient(to bottom, rgba(2,14,30,0.02) 0%, rgba(2,14,30,0.08) 36%, rgba(2,14,30,0.42) 100%)",
        }}
      />
      {landscape ? (
        <>
          <QuestionProgressBadge
            current={question.questionNumber}
            total={totalQuestions}
          />
          <div
            style={{
              position: "absolute",
              top: 165,
              left: 70,
              right: 70,
              height: 320,
              borderRadius: 30,
              backgroundColor: "rgba(255,255,255,0.96)",
              border: "5px solid rgba(45,139,215,0.78)",
              boxShadow: "0 10px 24px rgba(27,72,105,0.2)",
              opacity: 1 - revealProgress,
              transform: `translateY(${revealProgress * 25}px)`,
            }}
          >
            <div
              style={{
                position: "absolute",
                left: 72,
                right: 245,
                top: 40,
                bottom: 40,
                display: "flex",
                alignItems: "center",
                color: colors.ink,
                fontSize: landscapeQuestionFit.fontSize,
                lineHeight: landscapeQuestionFit.lineHeight,
                fontWeight: 900,
                textAlign: "center",
                justifyContent: "center",
                letterSpacing: 0,
              }}
            >
              {question.question}
            </div>
            <div style={{ position: "absolute", right: 56, top: 91 }}>
              <Timer
                localFrame={frame}
                countdownStart={timing.countdownStart}
                revealStart={timing.revealStart}
                fps={fps}
              />
            </div>
          </div>
          <div
            style={{
              position: "absolute",
              left: 80,
              right: 80,
              top: 510,
              display: "grid",
              gridTemplateColumns: "repeat(4, minmax(0, 1fr))",
              gap: 20,
              opacity: 1 - revealProgress,
              transform: `translateY(${revealProgress * 35}px)`,
            }}
          >
            {question.choices.map((choice, choiceIndex) => {
              const badgeIndex =
                (question.questionNumber + choiceIndex) %
                presentation.badges.length;
              return (
                <LandscapeChoiceCard
                  key={choice.choiceId}
                  choice={choice}
                  letter={String.fromCharCode(65 + choiceIndex)}
                  badge={presentation.badges[badgeIndex]}
                  accent={badgeAccents[badgeIndex]}
                />
              );
            })}
          </div>
          {frame >= timing.revealStart ? (
            <LandscapeAnswerOverlay
              answer={answer}
              explanation={question.explanation}
              revealProgress={revealProgress}
              explanationProgress={explanationProgress}
            />
          ) : null}
        </>
      ) : (
        <>
          <QuestionProgressBadge
            current={question.questionNumber}
            total={totalQuestions}
          />
          <div
            style={{
              position: "absolute",
              top: 400,
              left: 64,
              right: 64,
              height: 650,
              backgroundColor: "rgba(247,251,255,0.96)",
              borderTop: `10px solid ${colors.yellow}`,
              borderBottom: `10px solid ${colors.orange}`,
              boxShadow: "0 18px 38px rgba(0,0,0,0.42)",
              display: "flex",
              alignItems: "center",
              padding: "46px 38px 46px 52px",
              gap: 34,
              opacity: 1 - revealProgress,
              transform: `translateY(${revealProgress * 30}px)`,
            }}
          >
            <div
              style={{
                flex: 1,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                color: colors.ink,
                fontSize: portraitQuestionFit.fontSize,
                lineHeight: portraitQuestionFit.lineHeight,
                fontWeight: 900,
                textAlign: "center",
                letterSpacing: 0,
              }}
            >
              {question.question}
            </div>
            <Timer
              localFrame={frame}
              countdownStart={timing.countdownStart}
              revealStart={timing.revealStart}
              fps={fps}
            />
          </div>
          <div
            style={{
              position: "absolute",
              bottom: 42,
              left: 70,
              right: 70,
              display: "grid",
              gridTemplateColumns: "1fr 1fr",
              gap: 22,
              opacity: 1 - revealProgress,
              transform: `translateY(${revealProgress * 45}px)`,
            }}
          >
            {question.choices.map((choice) => (
              <ChoiceCard key={choice.choiceId} choice={choice} />
            ))}
          </div>
          {frame >= timing.revealStart ? (
            <AnswerOverlay
              answer={answer}
              explanation={question.explanation}
              revealProgress={revealProgress}
              explanationProgress={explanationProgress}
            />
          ) : null}
        </>
      )}

      <Sequence from={QUESTION_LEAD_FRAMES} layout="none">
        <Html5Audio src={staticFile(question.questionAudio)} />
      </Sequence>
      <Sequence from={timing.countdownStart} layout="none">
        <Html5Audio src={staticFile(timerAudio)} volume={0.82} />
      </Sequence>
      <Sequence from={timing.explanationStart} layout="none">
        <Html5Audio src={staticFile(question.explanationAudio)} />
      </Sequence>
    </AbsoluteFill>
  );
};

const FullBackground: React.FC<{ source: string; fadeIn?: boolean }> = ({
  source,
  fadeIn = true,
}) => {
  const frame = useCurrentFrame();
  const opacity = fadeIn
    ? interpolate(frame, [0, FADE_FRAMES], [0, 1], {
        extrapolateLeft: "clamp",
        extrapolateRight: "clamp",
      })
    : 1;
  return (
    <AbsoluteFill style={{ opacity }}>
      <Background source={source} />
    </AbsoluteFill>
  );
};

export const QuizVideo: React.FC<{ data: QuizVideoData }> = ({ data }) => {
  const landscapeIntroFrames = introVideoFrames(data);
  let cursor = landscapeIntroFrames + INTRO_FRAMES;
  const sequences: React.ReactNode[] = [];

  data.questions.forEach((question, index) => {
    const timing = questionTiming(question, data.fps);
    sequences.push(
      <Sequence
        key={`question-${question.questionId}`}
        from={cursor}
        durationInFrames={timing.contentFrames}
      >
        <QuestionScene
          question={question}
          totalQuestions={data.totalQuestions}
          background={data.background}
          timerAudio={data.timerAudio}
          presentation={data.presentation}
        />
      </Sequence>,
    );
    cursor += timing.contentFrames;
    const backgroundFrames =
      index === data.questions.length - 1
        ? FINAL_BACKGROUND_FRAMES
        : TRANSITION_FRAMES;
    sequences.push(
      <Sequence
        key={`background-${question.questionId}`}
        from={cursor}
        durationInFrames={backgroundFrames}
      >
        <FullBackground source={data.background} />
      </Sequence>,
    );
    cursor += backgroundFrames;
  });

  return (
    <AbsoluteFill style={{ backgroundColor: colors.deep }}>
      <Background source={data.background} />
      {data.introVideo && landscapeIntroFrames > 0 ? (
        <Sequence from={0} durationInFrames={landscapeIntroFrames}>
          <OffthreadVideo
            src={staticFile(data.introVideo)}
            style={{ width: "100%", height: "100%", objectFit: "cover" }}
          />
        </Sequence>
      ) : null}
      <Sequence
        from={landscapeIntroFrames}
        durationInFrames={INTRO_FRAMES}
      >
        <FullBackground source={data.background} fadeIn={false} />
      </Sequence>
      {sequences}
    </AbsoluteFill>
  );
};
