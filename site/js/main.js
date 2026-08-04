const nav = document.querySelector('.nav');
const updateNav = () => nav?.classList.toggle('scrolled', window.scrollY > 20);
updateNav();
window.addEventListener('scroll', updateNav, { passive: true });

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const fadeTargets = document.querySelectorAll('.fade-in');
if (reduceMotion) {
  fadeTargets.forEach((element) => element.classList.add('visible'));
} else {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('visible');
      observer.unobserve(entry.target);
    });
  }, { threshold: 0.08, rootMargin: '0px 0px -5%' });
  fadeTargets.forEach((element) => observer.observe(element));
}

const lab = document.querySelector('[data-light-lab]');
if (lab) {
  const stage = lab.querySelector('.lab-stage');
  const color = lab.querySelector('[data-color]');
  const brightness = lab.querySelector('[data-brightness]');
  const output = lab.querySelector('output');
  const update = () => {
    const level = Number(brightness.value);
    const hex = color.value.toUpperCase();
    stage.style.setProperty('--lab-color', hex);
    stage.style.setProperty('--lab-brightness', String(level / 100));
    output.textContent = `${level}% · ${hex}`;
  };
  color.addEventListener('input', update);
  brightness.addEventListener('input', update);
  update();
}
